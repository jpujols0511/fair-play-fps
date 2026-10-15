from __future__ import annotations

from dataclasses import asdict, dataclass, field
import hashlib
import json
from math import isqrt
from typing import Iterable


TICK_RATE = 64
SUPPORTED_TICK_RATES = (64, 128)
INPUT_SCALE = 1000
MAX_SPEED = 48
ACCELERATION = 8
FRICTION = 6
FIRE_INTERVAL_TICKS = 8
MAGAZINE_SIZE = 12
# Hits and lag compensation (decision 0003). Distances are millimetres.
HIT_RADIUS = 400
MAX_RANGE = 50_000
DAMAGE = 25
MAX_REWIND_TICKS_AT_64 = 13  # about 200 ms at either supported profile
MAX_REWIND_TICKS = MAX_REWIND_TICKS_AT_64  # 64 Hz compatibility name
TRIG_SCALE = 1_000_000
# round(sin(k degrees) * TRIG_SCALE) for k = 0..90. Fixed integers so every
# implementation computes the same rays; never recompute at runtime.
SIN_TABLE = (
    0, 17452, 34899, 52336, 69756, 87156, 104528, 121869, 139173, 156434,
    173648, 190809, 207912, 224951, 241922, 258819, 275637, 292372, 309017, 325568,
    342020, 358368, 374607, 390731, 406737, 422618, 438371, 453990, 469472, 484810,
    500000, 515038, 529919, 544639, 559193, 573576, 587785, 601815, 615661, 629320,
    642788, 656059, 669131, 681998, 694658, 707107, 719340, 731354, 743145, 754710,
    766044, 777146, 788011, 798636, 809017, 819152, 829038, 838671, 848048, 857167,
    866025, 874620, 882948, 891007, 898794, 906308, 913545, 920505, 927184, 933580,
    939693, 945519, 951057, 956305, 961262, 965926, 970296, 974370, 978148, 981627,
    984808, 987688, 990268, 992546, 994522, 996195, 997564, 998630, 999391, 999848,
    1000000,
)


@dataclass(frozen=True)
class InputCommand:
    sequence: int
    move_x: int = 0
    move_y: int = 0
    yaw_millidegrees: int = 0
    fire: bool = False
    # Server tick the client was seeing when it acted (start-of-tick state, as
    # in the snapshot it last received); -1 means now. Used only to rewind
    # targets for lag compensation, never trusted beyond MAX_REWIND_TICKS.
    view_tick: int = -1


@dataclass
class PlayerState:
    x: int = 0
    y: int = 0
    velocity_x: int = 0
    velocity_y: int = 0
    yaw_millidegrees: int = 0
    health: int = 100
    ammunition: int = MAGAZINE_SIZE
    next_fire_tick: int = 0
    last_sequence: int = -1


@dataclass(frozen=True)
class EvidenceEvent:
    tick: int
    player_id: str
    category: str
    detail: dict[str, int | str | bool]


@dataclass
class SimulationResult:
    tick_rate: int
    ticks: int
    players: dict[str, PlayerState]
    position_remainders: dict[str, tuple[int, int]]
    evidence: list[EvidenceEvent]
    digest: str


def _bounded_axis(value: int) -> int:
    return max(-INPUT_SCALE, min(INPUT_SCALE, value))


def _approach_zero(value: int, amount: int) -> int:
    if value > 0:
        return max(0, value - amount)
    if value < 0:
        return min(0, value + amount)
    return 0


def _sin_quarter(millidegrees: int) -> int:
    index, fraction = divmod(millidegrees, 1000)
    if index >= 90:
        return SIN_TABLE[90]
    return SIN_TABLE[index] + (SIN_TABLE[index + 1] - SIN_TABLE[index]) * fraction // 1000


def sin_scaled(millidegrees: int) -> int:
    """sin(yaw) * TRIG_SCALE in integers: table plus linear interpolation."""
    quadrant, rest = divmod(millidegrees % 360_000, 90_000)
    if quadrant == 0:
        return _sin_quarter(rest)
    if quadrant == 1:
        return _sin_quarter(90_000 - rest)
    if quadrant == 2:
        return -_sin_quarter(rest)
    return -_sin_quarter(90_000 - rest)


def cos_scaled(millidegrees: int) -> int:
    return sin_scaled(millidegrees + 90_000)


def _limit_vector(x: int, y: int, maximum: int) -> tuple[int, int]:
    magnitude = isqrt(x * x + y * y)
    if magnitude <= maximum or magnitude == 0:
        return x, y
    return x * maximum // magnitude, y * maximum // magnitude


class AuthoritativeServer:
    def __init__(self, player_ids: Iterable[str], tick_rate: int = TICK_RATE):
        ids = tuple(player_ids)
        if not ids or len(set(ids)) != len(ids):
            raise ValueError("player identifiers must be unique and non-empty")
        if tick_rate not in SUPPORTED_TICK_RATES:
            raise ValueError(f"tick rate must be one of {SUPPORTED_TICK_RATES}")
        self.tick_rate = tick_rate
        self.tick = 0
        self.players = {player_id: PlayerState() for player_id in sorted(ids)}
        self.evidence: list[EvidenceEvent] = []
        self._queued: dict[str, InputCommand] = {}
        self._position_remainders = {
            player_id: [0, 0] for player_id in sorted(ids)
        }
        # Start-of-tick positions for lag compensation: tick -> {id: (x, y)}.
        self._history: dict[int, dict[str, tuple[int, int]]] = {}

    def submit(self, player_id: str, command: InputCommand) -> None:
        if player_id not in self.players:
            raise KeyError(player_id)
        state = self.players[player_id]
        if command.sequence <= state.last_sequence:
            self._record(player_id, "stale_input", {"sequence": command.sequence})
            return
        previous = self._queued.get(player_id)
        if previous is not None and command.sequence <= previous.sequence:
            self._record(player_id, "reordered_input", {"sequence": command.sequence})
            return
        self._queued[player_id] = command

    def step(self) -> None:
        self._history[self.tick] = {
            player_id: (state.x, state.y) for player_id, state in self.players.items()
        }
        self._history.pop(self.tick - self.max_rewind_ticks - 1, None)
        for player_id in sorted(self.players):
            state = self.players[player_id]
            # A missing input is a neutral tick: no move, no fire, same facing,
            # and no sequence number consumed, so the real input still counts
            # if it arrives late (decision 0002).
            command = self._queued.pop(
                player_id,
                InputCommand(sequence=state.last_sequence, yaw_millidegrees=state.yaw_millidegrees),
            )
            self._apply_input(player_id, state, command)
        self.tick += 1

    def _apply_input(
        self,
        player_id: str,
        state: PlayerState,
        command: InputCommand,
    ) -> None:
        move_x = _bounded_axis(command.move_x)
        move_y = _bounded_axis(command.move_y)
        if move_x != command.move_x or move_y != command.move_y:
            self._record(
                player_id,
                "input_clamped",
                {
                    "requested_x": command.move_x,
                    "requested_y": command.move_y,
                    "accepted_x": move_x,
                    "accepted_y": move_y,
                },
            )

        if move_x == 0:
            state.velocity_x = _approach_zero(
                state.velocity_x, FRICTION * TICK_RATE // self.tick_rate
            )
        else:
            state.velocity_x += (
                ACCELERATION * TICK_RATE * move_x
                // (self.tick_rate * INPUT_SCALE)
            )
        if move_y == 0:
            state.velocity_y = _approach_zero(
                state.velocity_y, FRICTION * TICK_RATE // self.tick_rate
            )
        else:
            state.velocity_y += (
                ACCELERATION * TICK_RATE * move_y
                // (self.tick_rate * INPUT_SCALE)
            )
        state.velocity_x, state.velocity_y = _limit_vector(
            state.velocity_x,
            state.velocity_y,
            MAX_SPEED,
        )

        remainder = self._position_remainders[player_id]
        remainder[0] += state.velocity_x * TICK_RATE
        remainder[1] += state.velocity_y * TICK_RATE
        delta_x, remainder[0] = _divide_with_remainder(
            remainder[0], self.tick_rate
        )
        delta_y, remainder[1] = _divide_with_remainder(
            remainder[1], self.tick_rate
        )
        state.x += delta_x
        state.y += delta_y
        state.yaw_millidegrees = command.yaw_millidegrees % 360_000
        state.last_sequence = command.sequence

        if command.fire:
            if state.health <= 0:
                self._record(player_id, "eliminated_fire_rejected", {})
            else:
                self._attempt_fire(player_id, state, command.view_tick)

    def _attempt_fire(self, player_id: str, state: PlayerState, view_tick: int = -1) -> None:
        if self.tick < state.next_fire_tick:
            self._record(
                player_id,
                "fire_cadence_rejected",
                {"next_legal_tick": state.next_fire_tick},
            )
            return
        if state.ammunition <= 0:
            self._record(player_id, "empty_fire_rejected", {})
            return
        state.ammunition -= 1
        state.next_fire_tick = self.tick + self.fire_interval_ticks
        self._record(
            player_id,
            "shot_accepted",
            {
                "origin_x": state.x,
                "origin_y": state.y,
                "yaw_millidegrees": state.yaw_millidegrees,
                "ammunition_after": state.ammunition,
            },
        )
        self._resolve_hit(player_id, state, view_tick)

    def _resolve_hit(self, player_id: str, state: PlayerState, view_tick: int) -> None:
        """Lag compensation: rewind other players to the start of the tick the
        shooter saw, at most MAX_REWIND_TICKS, then trace a ray along its yaw.
        The closest living target within HIT_RADIUS and MAX_RANGE is hit."""
        rewind = 0
        if view_tick > self.tick:
            self._record(player_id, "view_tick_invalid", {"view_tick": view_tick})
        elif view_tick >= 0:
            rewind = self.tick - view_tick
            if rewind > self.max_rewind_ticks:
                self._record(player_id, "rewind_limited", {"requested": rewind})
                rewind = self.max_rewind_ticks
        rewind = min(rewind, self.tick)
        seen = self._history[self.tick - rewind]
        dx, dy = cos_scaled(state.yaw_millidegrees), sin_scaled(state.yaw_millidegrees)
        best = None
        for target_id in sorted(self.players):
            if target_id == player_id or self.players[target_id].health <= 0:
                continue
            tx, ty = seen[target_id]
            vx, vy = tx - state.x, ty - state.y
            along = vx * dx + vy * dy
            if along < 0 or along > MAX_RANGE * TRIG_SCALE:
                continue
            if abs(vx * dy - vy * dx) > HIT_RADIUS * TRIG_SCALE:
                continue
            if best is None or along < best[1]:
                best = (target_id, along)
        if best is None:
            return
        target_id, along = best
        target = self.players[target_id]
        target.health = max(0, target.health - DAMAGE)
        self._record(player_id, "hit_confirmed", {
            "target": target_id, "damage": DAMAGE, "rewind_ticks": rewind,
            "distance": along // TRIG_SCALE,
        })
        if target.health == 0:
            self._record(target_id, "player_eliminated", {"by": player_id})

    def _record(
        self,
        player_id: str,
        category: str,
        detail: dict[str, int | str | bool],
    ) -> None:
        self.evidence.append(
            EvidenceEvent(
                tick=self.tick,
                player_id=player_id,
                category=category,
                detail=detail,
            )
        )

    def result(self) -> SimulationResult:
        payload = {
            "tick_rate": self.tick_rate,
            "ticks": self.tick,
            "players": {
                key: asdict(value) for key, value in sorted(self.players.items())
            },
            "position_remainders": {
                key: tuple(value)
                for key, value in sorted(self._position_remainders.items())
            },
            "evidence": [asdict(event) for event in self.evidence],
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return SimulationResult(
            tick_rate=self.tick_rate,
            ticks=self.tick,
            players=self.players,
            position_remainders={
                key: tuple(value)
                for key, value in sorted(self._position_remainders.items())
            },
            evidence=self.evidence,
            digest=hashlib.sha256(encoded).hexdigest(),
        )

    @property
    def fire_interval_ticks(self) -> int:
        return FIRE_INTERVAL_TICKS * self.tick_rate // TICK_RATE

    @property
    def max_rewind_ticks(self) -> int:
        return MAX_REWIND_TICKS_AT_64 * self.tick_rate // TICK_RATE


def run_commands(
    player_ids: Iterable[str],
    commands_by_tick: Iterable[dict[str, InputCommand]],
    tick_rate: int = TICK_RATE,
) -> SimulationResult:
    server = AuthoritativeServer(player_ids, tick_rate=tick_rate)
    for commands in commands_by_tick:
        for player_id, command in sorted(commands.items()):
            server.submit(player_id, command)
        server.step()
    return server.result()


def honest_commands(
    ticks: int,
    player_id: str = "honest",
    tick_rate: int = TICK_RATE,
):
    fire_interval = FIRE_INTERVAL_TICKS * tick_rate // TICK_RATE
    for tick in range(ticks):
        yield {
            player_id: InputCommand(
                sequence=tick,
                move_x=INPUT_SCALE if tick < ticks // 2 else 0,
                yaw_millidegrees=90_000,
                fire=tick % fire_interval == 0,
            )
        }


def controlled_attacker_commands(ticks: int, player_id: str = "attacker"):
    for tick in range(ticks):
        yield {
            player_id: InputCommand(
                sequence=tick,
                move_x=INPUT_SCALE * 5,
                move_y=-INPUT_SCALE * 4,
                yaw_millidegrees=450_000,
                fire=True,
            )
        }


def _divide_with_remainder(value: int, divisor: int) -> tuple[int, int]:
    quotient = abs(value) // divisor
    if value < 0:
        quotient = -quotient
    return quotient, value - quotient * divisor
