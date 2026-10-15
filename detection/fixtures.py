"""Labelled synthetic demos for calibration and tests.

Controlled fixtures that produce kernel command streams. They do not contain
real cheats and do not touch any other process.
"""
from __future__ import annotations

import random

from fairplay_sim import FIRE_INTERVAL_TICKS, INPUT_SCALE


def _cmd(seq, mx=0, my=0, yaw=0, fire=False):
    return {"sequence": seq, "move_x": mx, "move_y": my, "yaw_millidegrees": yaw % 360_000, "fire": fire}


def honest(ticks: int, seed: int, player_id: str = "p1") -> list:
    """Smooth turning, legal input, legal fire spacing, and network jitter:
    some packets arrive a tick late, which the kernel records as stale_input."""
    rng = random.Random(seed)
    demo, yaw, late, last_fire = [], rng.randrange(360_000), None, -100
    for t in range(ticks):
        yaw += rng.randint(-15_000, 15_000)
        fire = t - last_fire >= FIRE_INTERVAL_TICKS + rng.randint(0, 6) and rng.random() < 0.5
        if fire:
            last_fire = t
        cmd = _cmd(t, rng.randint(-INPUT_SCALE, INPUT_SCALE), rng.randint(-INPUT_SCALE, INPUT_SCALE), yaw, fire)
        submits = []
        if late is not None:
            submits.append([player_id, late])
            late = None
        if rng.random() < 0.1:
            late = cmd
        else:
            submits.append([player_id, cmd])
        demo.append(submits)
    return demo


def snapper(ticks: int, seed: int, player_id: str = "p1") -> list:
    """Legal movement and cadence, but turns more than 120 degrees in one tick
    and fires on that same tick every 16 ticks."""
    rng = random.Random(seed)
    demo, yaw = [], rng.randrange(360_000)
    for t in range(ticks):
        snap = t % 16 == 15
        yaw += rng.choice((-1, 1)) * 125_000 if snap else rng.randint(-5_000, 5_000)
        demo.append([[player_id, _cmd(t, rng.randint(-INPUT_SCALE, INPUT_SCALE), 0, yaw, snap)]])
    return demo


def speeder(ticks: int, seed: int, player_id: str = "p1") -> list:
    rng = random.Random(seed)
    return [[[player_id, _cmd(t, INPUT_SCALE * 4, -INPUT_SCALE * 3, rng.randrange(360_000) // 50, t % 8 == 0)]]
            for t in range(ticks)]
