#!/usr/bin/env python3
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "prototype"))

from fairplay_sim import (  # noqa: E402
    controlled_attacker_commands,
    honest_commands,
    run_commands,
)


def summary(name, result):
    categories = {}
    for event in result.evidence:
        categories[event.category] = categories.get(event.category, 0) + 1
    return {
        "scenario": name,
        "ticks": result.ticks,
        "digest": result.digest,
        "players": {
            player_id: {
                "position": [state.x, state.y],
                "velocity": [state.velocity_x, state.velocity_y],
                "ammunition": state.ammunition,
            }
            for player_id, state in result.players.items()
        },
        "evidence_categories": categories,
    }


honest = run_commands(["honest"], honest_commands(32))
attacker = run_commands(["attacker"], controlled_attacker_commands(32))
print(json.dumps([summary("honest", honest), summary("attacker", attacker)], indent=2))
