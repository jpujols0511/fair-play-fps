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
        self.assertLessEqual(
            state.velocity_x * state.velocity_x + state.velocity_y * state.velocity_y,
            MAX_SPEED * MAX_SPEED,
        )
        self.assertNotIn("input_clamped", [event.category for event in result.evidence])

    def test_impossible_input_is_clamped_and_recorded(self):
        result = run_commands(["attacker"], controlled_attacker_commands(2))
        categories = [event.category for event in result.evidence]
        self.assertIn("input_clamped", categories)
        state = result.players["attacker"]
        self.assertLessEqual(
            state.velocity_x * state.velocity_x + state.velocity_y * state.velocity_y,
            MAX_SPEED * MAX_SPEED,
        )

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

    def test_missing_input_is_neutral_and_consumes_no_sequence(self):
        # Decision 0002: a tick with no input keeps facing, does not move or
        # fire, and leaves the sequence free so a late input still counts.
        server = AuthoritativeServer(["player"])
        server.submit("player", InputCommand(sequence=0, yaw_millidegrees=45_000))
        server.step()
        server.step()
        state = server.players["player"]
        self.assertEqual((state.last_sequence, state.yaw_millidegrees), (0, 45_000))
        server.submit("player", InputCommand(sequence=1, move_x=INPUT_SCALE, yaw_millidegrees=46_000))
        server.step()
        self.assertEqual(server.players["player"].last_sequence, 1)
        self.assertNotIn("stale_input", [event.category for event in server.evidence])

    def test_same_commands_produce_same_digest(self):
        first = run_commands(["honest"], honest_commands(64))
        second = run_commands(["honest"], honest_commands(64))
        self.assertEqual(first.digest, second.digest)

    def test_64_and_128_tick_profiles_preserve_one_second_contract(self):
        results = {
            tick_rate: run_commands(
                ["honest"],
                honest_commands(tick_rate, tick_rate=tick_rate),
                tick_rate=tick_rate,
            )
            for tick_rate in (64, 128)
        }
        sixty_four = results[64]
        one_twenty_eight = results[128]
        self.assertEqual(
            sixty_four.players["honest"].x,
            one_twenty_eight.players["honest"].x,
        )
        self.assertEqual(
            sixty_four.players["honest"].velocity_x,
            one_twenty_eight.players["honest"].velocity_x,
        )
        self.assertEqual(
            sixty_four.players["honest"].ammunition,
            one_twenty_eight.players["honest"].ammunition,
        )
        self.assertEqual(
            sixty_four.position_remainders["honest"],
            one_twenty_eight.position_remainders["honest"],
        )
        self.assertEqual(
            [event.category for event in sixty_four.evidence],
            [event.category for event in one_twenty_eight.evidence],
        )
        self.assertNotEqual(sixty_four.digest, one_twenty_eight.digest)

    def test_unsupported_tick_rate_is_rejected(self):
        with self.assertRaises(ValueError):
            AuthoritativeServer(["player"], tick_rate=120)


if __name__ == "__main__":
    unittest.main()
