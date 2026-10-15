"""Asynchronous detection over a recorded match directory.

    python3 -m detection.run --match DIR [--population 10 --hour 21 --coverage 0.5]

DIR holds demo.json and result.json written by godot/net/server.gd. Runs as a
separate process after the match, so it never affects live performance.
Prints flags and review priority per player as JSON. Issues no punishment.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import fixtures
from .features import replay
from .pipeline import Context, Detector, review_priority

DETECTOR_VERSION = "rules-0.1"


def default_detector() -> Detector:
    clean = [replay(["p1"], fixtures.honest(512, seed))[0]["p1"] for seed in range(40)]
    return Detector.calibrate(clean, DETECTOR_VERSION)


def analyse(match_dir: Path, context: Context, detector: Detector | None = None) -> dict:
    result = json.loads((match_dir / "result.json").read_text())
    demo = json.loads((match_dir / "demo.json").read_text())
    players = sorted(result["players"])
    tick_rate = result.get("tick_rate", 64)
    timelines, digest = replay(players, demo, tick_rate=tick_rate)
    if digest != result["digest"]:
        raise ValueError("demo does not reproduce the server's recorded digest")
    detector = detector or default_detector()
    report = {"digest": digest, "tick_rate": tick_rate,
              "detector_version": detector.version, "players": {}}
    for player_id, timeline in timelines.items():
        flags = detector.flags(timeline)
        report["players"][player_id] = {
            "priority": review_priority(flags, context),
            "flags": [flag.as_dict() for flag in flags],
        }
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--match", required=True, type=Path)
    parser.add_argument("--population", type=int, default=10)
    parser.add_argument("--hour", type=int, default=12)
    parser.add_argument("--coverage", type=float, default=1.0)
    args = parser.parse_args()
    print(json.dumps(analyse(args.match, Context(args.population, args.hour, args.coverage)), indent=2))


if __name__ == "__main__":
    main()
