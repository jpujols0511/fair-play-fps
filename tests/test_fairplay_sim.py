from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "prototype"))

from fairplay_sim import (  # noqa: E402
    DAMAGE,
    FIRE_INTERVAL_TICKS,
    INPUT_SCALE,
    MAX_REWIND_TICKS,
    MAX_SPEED,
    AuthoritativeServer,
    cos_scaled,
    sin_scaled,
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



def _place(server, player_id, x, y):
    state = server.players[player_id]
    state.x, state.y = x, y


def _categories(server, player_id=None):
    return [e.category for e in server.evidence if player_id is None or e.player_id == player_id]


class HitAndLagCompensationTests(unittest.TestCase):
    """Decision 0003: the server traces every accepted shot itself and rewinds
    targets to the tick the shooter saw, never more than MAX_REWIND_TICKS."""

    def test_integer_trig_matches_the_circle(self):
        for md, (c, s) in {0: (1_000_000, 0), 90_000: (0, 1_000_000), 180_000: (-1_000_000, 0),
                           270_000: (0, -1_000_000), -90_000: (0, -1_000_000)}.items():
            self.assertEqual((cos_scaled(md), sin_scaled(md)), (c, s), md)
        import math
        for md in range(0, 360_000, 7_919):
            self.assertAlmostEqual(sin_scaled(md) / 1e6, math.sin(math.radians(md / 1000)), delta=5e-5)

    def test_shot_straight_ahead_hits_and_one_to_the_side_misses(self):
        server = AuthoritativeServer(["a", "b", "c"])
        _place(server, "b", 5_000, 0)
        _place(server, "c", 5_000, 3_000)
        server.submit("a", InputCommand(sequence=0, yaw_millidegrees=0, fire=True))
        server.step()
        hits = [e for e in server.evidence if e.category == "hit_confirmed"]
        self.assertEqual([h.detail["target"] for h in hits], ["b"])
        self.assertEqual(hits[0].detail["distance"], 5_000)
        self.assertEqual((server.players["b"].health, server.players["c"].health), (100 - DAMAGE, 100))

    def test_closest_target_on_the_ray_takes_the_hit(self):
        server = AuthoritativeServer(["a", "b", "c"])
        _place(server, "b", 9_000, 100)
        _place(server, "c", 4_000, -100)
        server.submit("a", InputCommand(sequence=0, fire=True))
        server.step()
        self.assertEqual(server.players["c"].health, 100 - DAMAGE)
        self.assertEqual(server.players["b"].health, 100)

    def _moving_target(self, fire_tick, view_tick):
        # b stands on a's line of fire for ticks 0-4, then 3 m to the side.
        server = AuthoritativeServer(["a", "b"])
        _place(server, "b", 2_000, 0)
        for tick in range(fire_tick + 1):
            if tick == 5:
                _place(server, "b", 2_000, 3_000)
            if tick == fire_tick:
                server.submit("a", InputCommand(sequence=0, fire=True, view_tick=view_tick))
            server.step()
        return server

    def test_lag_compensation_hits_what_the_shooter_saw(self):
        server = self._moving_target(fire_tick=10, view_tick=3)
        hit = next(e for e in server.evidence if e.category == "hit_confirmed")
        self.assertEqual(hit.detail["rewind_ticks"], 7)
        self.assertEqual(server.players["b"].health, 100 - DAMAGE)

    def test_without_rewind_the_same_shot_misses(self):
        server = self._moving_target(fire_tick=10, view_tick=-1)
        self.assertNotIn("hit_confirmed", _categories(server))

    def test_rewind_is_bounded(self):
        # Claiming to have seen tick 2 at tick 40 rewinds only to tick 27,
        # where b is already off the line: a forged old view buys nothing.
        server = self._moving_target(fire_tick=40, view_tick=2)
        self.assertIn("rewind_limited", _categories(server, "a"))
        self.assertNotIn("hit_confirmed", _categories(server))
        self.assertEqual(MAX_REWIND_TICKS, 13)

    def test_view_from_the_future_is_not_used(self):
        server = self._moving_target(fire_tick=10, view_tick=12)
        self.assertIn("view_tick_invalid", _categories(server, "a"))
        self.assertNotIn("hit_confirmed", _categories(server))

    def test_elimination_stops_hits_and_fire(self):
        server = AuthoritativeServer(["a", "b"])
        _place(server, "b", 3_000, 0)
        sequence = 0
        for tick in range(6 * FIRE_INTERVAL_TICKS):
            if tick % FIRE_INTERVAL_TICKS == 0:
                server.submit("a", InputCommand(sequence=sequence, fire=True))
                server.submit("b", InputCommand(sequence=sequence, yaw_millidegrees=180_000, fire=True))
                sequence += 1
            server.step()
        self.assertEqual(server.players["b"].health, 0)
        self.assertEqual(_categories(server, "b").count("player_eliminated"), 1)
        self.assertEqual(_categories(server, "a").count("hit_confirmed"), 100 // DAMAGE)
        self.assertIn("eliminated_fire_rejected", _categories(server, "b"))


if __name__ == "__main__":
    unittest.main()
