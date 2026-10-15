"""Blind review cases: raw gameplay only, with every identity replaced by a
case-local label. No names, ranks, friend links, detector flags or scores."""
from __future__ import annotations

import json
import random
import string

from detection.features import Timeline


def build_blind_case(timelines: dict[str, Timeline], subject: str, rng: random.Random) -> dict:
    others = [p for p in timelines if p != subject]
    rng.shuffle(others)
    labels = {subject: "A", **{p: string.ascii_uppercase[i + 1] for i, p in enumerate(others)}}
    ticks = len(timelines[subject].yaw)
    frames = []
    for t in range(ticks):
        frames.append({
            labels[p]: {
                "x": tl.position[t][0], "y": tl.position[t][1],
                "yaw": tl.yaw[t], "shot": t in tl.fired_ticks,
            }
            for p, tl in timelines.items()
        })
    case = {"case_id": "%032x" % rng.getrandbits(128), "subject": "A", "ticks": ticks, "frames": frames}
    text = json.dumps(case)
    for player_id in timelines:
        if f'"{player_id}"' in text:
            raise ValueError("identity leaked into a blind case")
    return case
