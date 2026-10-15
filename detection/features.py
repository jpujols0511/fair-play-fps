"""Replay a demo through the authoritative kernel and extract temporal and
behavioural features per player, in fixed windows of ticks."""
from __future__ import annotations

from dataclasses import dataclass

from fairplay_sim import AuthoritativeServer, InputCommand

WINDOW_TICKS = 128
SNAP_MILLIDEGREES = 90_000  # more than 90 degrees of yaw in one tick
FIRE_CATEGORIES = ("shot_accepted", "fire_cadence_rejected", "empty_fire_rejected")
# Evidence caused by network conditions. Kept for diagnosis, never used as
# suspicion: the Godot spike showed honest late packets produce stale_input.
NEVER_SUSPICION = frozenset({"stale_input", "reordered_input"})


@dataclass(frozen=True)
class Timeline:
    player_id: str
    yaw: tuple[int, ...]          # accepted yaw after each tick
    position: tuple[tuple[int, int], ...]
    fired_ticks: frozenset[int]   # ticks with an accepted shot
    evidence: tuple               # this player's EvidenceEvents


def replay(player_ids, demo) -> tuple[dict[str, Timeline], str]:
    """Rebuild every player's timeline from a demo (list of per-tick submits)."""
    server = AuthoritativeServer(player_ids)
    yaw = {p: [] for p in server.players}
    position = {p: [] for p in server.players}
    for submits in demo:
        for player_id, command in submits:
            server.submit(player_id, InputCommand(**command))
        server.step()
        for player_id, state in server.players.items():
            yaw[player_id].append(state.yaw_millidegrees)
            position[player_id].append((state.x, state.y))
    timelines = {}
    for player_id in server.players:
        evidence = tuple(e for e in server.evidence if e.player_id == player_id)
        fired = frozenset(e.tick for e in evidence if e.category == "shot_accepted")
        timelines[player_id] = Timeline(player_id, tuple(yaw[player_id]),
                                        tuple(position[player_id]), fired, evidence)
    return timelines, server.result().digest


def yaw_delta(a: int, b: int) -> int:
    d = (b - a) % 360_000
    return min(d, 360_000 - d)


def window_features(t: Timeline, start: int, end: int) -> dict[str, float]:
    ticks = max(1, end - start)
    events = [e for e in t.evidence if start <= e.tick < end and e.category not in NEVER_SUSPICION]
    clamped = sum(1 for e in events if e.category == "input_clamped")
    cadence = sum(1 for e in events if e.category == "fire_cadence_rejected")
    attempts = sum(1 for e in events if e.category in FIRE_CATEGORIES)
    snaps = snap_then_fire = 0
    for i in range(max(start, 1), min(end, len(t.yaw))):
        if yaw_delta(t.yaw[i - 1], t.yaw[i]) > SNAP_MILLIDEGREES:
            snaps += 1
            if i in t.fired_ticks:
                snap_then_fire += 1
    return {
        "clamp_rate": clamped / ticks,
        "cadence_reject_rate": cadence / attempts if attempts else 0.0,
        "snap_rate": snaps / ticks,
        "snap_then_fire": float(snap_then_fire),
    }


def windows(t: Timeline, size: int = WINDOW_TICKS) -> list[dict]:
    n = len(t.yaw)
    return [{"start": s, "end": min(n, s + size), **window_features(t, s, min(n, s + size))}
            for s in range(0, max(n, 1), size)]
