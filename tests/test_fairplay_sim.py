from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "prototype"))

from fairplay_sim import (  # noqa: E402
    FIRE_INTERVAL_TICKS,
    INPUT_SCALE,
    MAX_SPEED,
    AuthoritativeServer,
    InputCommand,
    controlled_attacker_commands,
    honest_commands,
    run_commands,
)


class AuthoritativeSimulationTests(unittest.TestCase):
    def test_input_cannot_submit_authoritative_state(self):
        fields = set(InputCommand.__dataclass_fields__)
        self.assertFalse(fields & {"x", "y", "health", "damage", "ammunition", "score"})

    def test_honest_movement_stays_within_speed_limit(self):
        result = run_commands(["honest"], honest_commands(64))
        state = result.players["honest"]
        self.assertLessEqual(state.velocity_x * state.velocity_x + state.velocity_y * state.velocity_y, MAX_SPEED * MAX_SPEED)
        self.assertNotIn("input_clamped", [event.category for event in result.evidence])

    def test_impossible_input_is_clamped_and_recorded(self):
        result = run_commands(["attacker"], controlled_attacker_commands(2))
        categories = [event.category for event in result.evidence]
        self.assertIn("input_clamped", categories)
        state = result.players["attacker"]
        self.assertLessEqual(state.velocity_x * state.velocity_x + state.velocity_y * state.velocity_y, MAX_SPEED * MAX_SPEED)

    def test_fire_cadence_is_server_enforced(self):
        result = run_commands(["attacker"], controlled_attacker_commands(FIRE_INTERVAL_TICKS))
        categories = [event.category for event in result.evidence]
        self.assertEqual(categories.count("shot_accepted"), 1)
        self.assertEqual(categories.count("fire_cadence_rejected"), FIRE_INTERVAL_TICKS - 1)

    def test_stale_input_is_evidence_and_does_not_replace_newer_input(self):
        server = AuthoritativeServer(["player"])
        server.submit("player", InputCommand(sequence=1, move_x=INPUT_SCALE))
        server.submit("player", InputCommand(sequence=0, move_x=-INPUT_SCALE))
        server.step()
        self.assertEqual(server.players["player"].last_sequence, 1)
        self.assertIn("reordered_input", [event.category for event in server.evidence])

    def test_same_commands_produce_same_digest(self):
        first = run_commands(["honest"], honest_commands(64))
        second = run_commands(["honest"], honest_commands(64))
        self.assertEqual(first.digest, second.digest)


if __name__ == "__main__":
    unittest.main()
