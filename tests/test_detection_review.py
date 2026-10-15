"""Detection pipeline and community review, end to end on labelled fixtures."""
from pathlib import Path
import json
import random
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from detection import fixtures  # noqa: E402
from detection.bans import BanDatabase  # noqa: E402
from detection.features import NEVER_SUSPICION, replay  # noqa: E402
from detection.pipeline import CalibrationError, Context, Detector, review_priority  # noqa: E402
from review.cases import build_blind_case  # noqa: E402
from review.consensus import ReviewBoard, mix_queue  # noqa: E402


def timeline(demo, player="p1"):
    return replay([player], demo)[0][player]


CLEAN = [timeline(fixtures.honest(512, s)) for s in range(40)]
DETECTOR = Detector.calibrate(CLEAN, "test")


class Detection(unittest.TestCase):
    def test_no_flags_on_held_out_clean_play(self):
        held_out = [timeline(fixtures.honest(512, s)) for s in range(1000, 1060)]
        self.assertEqual([f for t in held_out for f in DETECTOR.flags(t)], [])

    def test_network_jitter_never_counts(self):
        stale = sum(1 for t in CLEAN for e in t.evidence if e.category in NEVER_SUSPICION)
        self.assertGreater(stale, 0, "fixture should include late packets")
        self.assertEqual([f for t in CLEAN for f in DETECTOR.flags(t)], [])

    def test_snapper_flagged_with_explanation(self):
        flags = DETECTOR.flags(timeline(fixtures.snapper(256, 7)))
        features = {f.feature for f in flags}
        self.assertIn("snap_then_fire", features)
        flag = flags[0]
        self.assertGreater(flag.value, flag.threshold)
        self.assertTrue(flag.explanation)
        self.assertEqual(flag.detector_version, "test")

    def test_speeder_flagged(self):
        self.assertIn("clamp_rate", {f.feature for f in DETECTOR.flags(timeline(fixtures.speeder(128, 3)))})

    def test_calibration_refuses_to_flag_clean_play(self):
        bad = Detector({"clamp_rate": -1.0, "cadence_reject_rate": 1, "snap_rate": 1, "snap_then_fire": 99}, "bad")
        self.assertTrue(bad.flags(CLEAN[0]))
        with self.assertRaises(CalibrationError):
            Detector.calibrate.__func__(type("Strict", (Detector,), {"flags": lambda self, t: ["x"]}), CLEAN[:1], "x")

    def test_context_changes_priority_only(self):
        flags = DETECTOR.flags(timeline(fixtures.snapper(256, 7)))
        busy = review_priority(flags, Context(population=40, hour_utc=3, moderation_coverage=0.0))
        quiet = review_priority(flags, Context(population=2, hour_utc=15, moderation_coverage=1.0))
        self.assertGreater(busy, quiet)
        self.assertEqual(review_priority([], Context(64, 3, 0.0)), 0.0)


class Review(unittest.TestCase):
    def test_blind_case_hides_identity(self):
        demo = [[["mallory", c[1]], ["alice", {**c[1], "fire": False}]]
                for c in (s[0] for s in fixtures.snapper(64, 1, "mallory"))]
        timelines, _ = replay(["alice", "mallory"], demo)
        case = build_blind_case(timelines, "mallory", random.Random(0))
        text = json.dumps(case)
        self.assertNotIn("mallory", text)
        self.assertNotIn("alice", text)
        self.assertEqual(case["subject"], "A")
        self.assertNotIn("flags", case)

    def test_consensus_needs_three_weighted_reviewers(self):
        board = ReviewBoard()
        for r in ("r1", "r2"):
            board.submit(r, "case", True)
        self.assertEqual(board.decide("case").outcome, "insufficient")
        board.submit("r3", "case", True)
        decision = board.decide("case")
        self.assertEqual((decision.outcome, decision.final), ("cheating", True))

    def test_seeds_remove_a_reviewer_who_always_says_cheating(self):
        board = ReviewBoard()
        for i in range(6):
            board.add_seed(f"seed{i}", is_cheating=i % 2 == 0)
            board.submit("always_yes", f"seed{i}", True)
            for r in ("r1", "r2", "r3"):
                board.submit(r, f"seed{i}", i % 2 == 0)
        self.assertFalse(board.reviewer("always_yes").eligible)
        for r in ("always_yes", "r1", "r2", "r3"):
            board.submit(r, "real", r == "always_yes")
        decision = board.decide("real")
        self.assertNotIn("always_yes", decision.reviewers)
        self.assertEqual(decision.outcome, "clean")

    def test_queue_mixes_in_seeds(self):
        queue = mix_queue([f"c{i}" for i in range(12)], [f"s{i}" for i in range(10)], random.Random(1))
        self.assertEqual(sum(1 for c in queue if c.startswith("s")), 4)
        self.assertEqual(sum(1 for c in queue if c.startswith("c")), 12)


class Cycle(unittest.TestCase):
    """Flag -> blind review -> consensus -> moderator -> banned database -> training data."""

    def test_full_cycle(self):
        timelines, _ = replay(["p1"], fixtures.snapper(256, 11))
        flags = DETECTOR.flags(timelines["p1"])
        self.assertTrue(flags)
        case = build_blind_case(timelines, "p1", random.Random(2))
        board = ReviewBoard()
        for r in ("r1", "r2", "r3"):
            board.submit(r, case["case_id"], True)
        decision = board.decide(case["case_id"])
        bans = BanDatabase()
        self.addCleanup(bans.close)
        with self.assertRaises(PermissionError):
            bans.record(decision, "p1", [], moderator="")
        bans.record(decision, "p1", [f.as_dict() for f in flags], moderator="mod-on-duty")
        self.assertTrue(bans.is_banned("p1"))
        rows = bans.training_rows()
        self.assertTrue(rows and all(label for _, label in rows))

    def test_detector_cannot_ban_without_final_review(self):
        board = ReviewBoard()
        board.submit("r1", "case", True)
        with BanDatabase() as bans, self.assertRaises(PermissionError):
            bans.record(board.decide("case"), "p1", [], moderator="mod")


if __name__ == "__main__":
    unittest.main()
