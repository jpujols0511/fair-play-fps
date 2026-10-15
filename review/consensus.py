"""Weighted consensus with seeded ground truth.

- Several independent reviewers per case; one reviewer, one verdict.
- A reviewer's weight is earned by matching verified outcomes and seeds.
- Known-cheater and known-clean seed cases, indistinguishable from real ones,
  are mixed into every queue. Reviewers who fail seeds lose weight and, below
  the accuracy floor, stop counting at all.
- A decision is a recommendation. Recording it needs a named moderator
  (detection.bans.BanDatabase.record).
"""
from __future__ import annotations

from dataclasses import dataclass, field
import random

MIN_REVIEWERS = 3
MIN_TOTAL_WEIGHT = 1.5
DECISIVE_SHARE = 0.8
START_WEIGHT = 0.5
MAX_WEIGHT = 3.0
SEED_ACCURACY_FLOOR = 0.8
SEEDS_BEFORE_JUDGING = 3


@dataclass
class Reviewer:
    reviewer_id: str
    weight: float = START_WEIGHT
    seeds_seen: int = 0
    seeds_correct: int = 0

    @property
    def eligible(self) -> bool:
        if self.seeds_seen < SEEDS_BEFORE_JUDGING:
            return True
        return self.seeds_correct / self.seeds_seen >= SEED_ACCURACY_FLOOR


@dataclass(frozen=True)
class Decision:
    case_id: str
    outcome: str            # "cheating", "clean" or "insufficient"
    final: bool
    weight_cheating: float
    weight_total: float
    reviewers: tuple[str, ...]


@dataclass
class ReviewBoard:
    reviewers: dict[str, Reviewer] = field(default_factory=dict)
    seeds: dict[str, bool] = field(default_factory=dict)
    verdicts: dict[str, dict[str, bool]] = field(default_factory=dict)

    def reviewer(self, reviewer_id: str) -> Reviewer:
        return self.reviewers.setdefault(reviewer_id, Reviewer(reviewer_id))

    def add_seed(self, case_id: str, is_cheating: bool) -> None:
        self.seeds[case_id] = is_cheating

    def submit(self, reviewer_id: str, case_id: str, says_cheating: bool) -> None:
        reviewer = self.reviewer(reviewer_id)
        if case_id in self.seeds:
            reviewer.seeds_seen += 1
            if says_cheating == self.seeds[case_id]:
                reviewer.seeds_correct += 1
                reviewer.weight = min(MAX_WEIGHT, reviewer.weight + 0.25)
            else:
                reviewer.weight *= 0.5
            return
        self.verdicts.setdefault(case_id, {})[reviewer_id] = says_cheating

    def decide(self, case_id: str) -> Decision:
        votes = {r: v for r, v in self.verdicts.get(case_id, {}).items() if self.reviewer(r).eligible}
        total = sum(self.reviewer(r).weight for r in votes)
        cheating = sum(self.reviewer(r).weight for r, v in votes.items() if v)
        names = tuple(sorted(votes))
        if len(votes) < MIN_REVIEWERS or total < MIN_TOTAL_WEIGHT:
            return Decision(case_id, "insufficient", False, cheating, total, names)
        share = cheating / total
        if share >= DECISIVE_SHARE:
            return Decision(case_id, "cheating", True, cheating, total, names)
        if share <= 1 - DECISIVE_SHARE:
            return Decision(case_id, "clean", True, cheating, total, names)
        return Decision(case_id, "insufficient", False, cheating, total, names)

    def learn(self, case_id: str, verified_cheating: bool) -> None:
        """After an outcome is verified, adjust everyone who reviewed the case."""
        for reviewer_id, said in self.verdicts.get(case_id, {}).items():
            reviewer = self.reviewer(reviewer_id)
            if said == verified_cheating:
                reviewer.weight = min(MAX_WEIGHT, reviewer.weight + 0.1)
            else:
                reviewer.weight *= 0.8


def mix_queue(real_case_ids: list[str], seed_case_ids: list[str], rng: random.Random,
              seed_every: int = 4) -> list[str]:
    """Interleave seeds so roughly one in `seed_every` items is a seed."""
    queue = list(real_case_ids)
    seeds = list(seed_case_ids)
    rng.shuffle(seeds)
    wanted = max(1, len(queue) // max(1, seed_every - 1))
    for case_id in seeds[:wanted]:
        queue.insert(rng.randrange(len(queue) + 1), case_id)
    return queue
