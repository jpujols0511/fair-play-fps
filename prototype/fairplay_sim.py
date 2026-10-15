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


@dataclass(frozen=True)
class InputCommand:
    sequence: int
    move_x: int = 0
    move_y: int = 0
    yaw_millidegrees: int = 0
    fire: bool = False


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
        for player_id in sorted(self.players):
            state = self.players[player_id]
            command = self._queued.pop(
                player_id,
                InputCommand(sequence=state.last_sequence + 1),
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
                state.velocity_x,
                FRICTION * TICK_RATE // self.tick_rate,
            )
        else:
            state.velocity_x += (
                ACCELERATION * TICK_RATE * move_x
                // (self.tick_rate * INPUT_SCALE)
            )
        if move_y == 0:
            state.velocity_y = _approach_zero(
                state.velocity_y,
                FRICTION * TICK_RATE // self.tick_rate,
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
            self._attempt_fire(player_id, state)

    def _attempt_fire(self, player_id: str, state: PlayerState) -> None:
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
