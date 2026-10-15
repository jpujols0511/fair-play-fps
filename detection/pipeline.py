"""Explainable rules, calibration against known-clean play, and context
weighting for the review queue."""
from __future__ import annotations

from dataclasses import asdict, dataclass

from .features import Timeline, windows


@dataclass(frozen=True)
class Rule:
    feature: str
    floor: float          # threshold never goes below this
    explanation: str


RULES = (
    Rule("clamp_rate", 0.0,
         "Requested movement outside the legal input range. Unmodified clients "
         "limit input locally, so this only appears with modified input."),
    Rule("cadence_reject_rate", 0.25,
         "Asked to fire faster than the weapon allows on a large share of attempts."),
    Rule("snap_rate", 0.02,
         "Turned more than 90 degrees within a single tick, repeatedly."),
    Rule("snap_then_fire", 2.0,
         "Fired on the same tick as a turn of more than 90 degrees, more than twice in a window."),
)


@dataclass(frozen=True)
class Flag:
    player_id: str
    feature: str
    value: float
    threshold: float
    window_start: int
    window_end: int
    explanation: str
    detector_version: str

    def as_dict(self) -> dict:
        return asdict(self)


class CalibrationError(RuntimeError):
    """Raised when a detector would flag known-clean play."""


@dataclass(frozen=True)
class Detector:
    thresholds: dict[str, float]
    version: str

    @classmethod
    def calibrate(cls, clean: list[Timeline], version: str, margin: float = 1.5) -> "Detector":
        """Set each threshold above the worst value seen in known-clean play.

        False positives are sacred: the result must flag none of the clean set.
        """
        worst = {rule.feature: 0.0 for rule in RULES}
        for timeline in clean:
            for window in windows(timeline):
                for rule in RULES:
                    worst[rule.feature] = max(worst[rule.feature], window[rule.feature])
        thresholds = {rule.feature: max(rule.floor, worst[rule.feature] * margin) for rule in RULES}
        detector = cls(thresholds, version)
        leaked = [f for t in clean for f in detector.flags(t)]
        if leaked:
            raise CalibrationError(f"{len(leaked)} flags on known-clean play")
        return detector

    def flags(self, timeline: Timeline) -> list[Flag]:
        out = []
        for window in windows(timeline):
            for rule in RULES:
                value = window[rule.feature]
                threshold = self.thresholds[rule.feature]
                if value > threshold:
                    out.append(Flag(timeline.player_id, rule.feature, round(value, 4), round(threshold, 4),
                                    window["start"], window["end"], rule.explanation, self.version))
        return out


@dataclass(frozen=True)
class Context:
    population: int               # players on the server
    hour_utc: int
    moderation_coverage: float    # share of the hour with a live moderator, 0..1


def review_priority(flags: list[Flag], context: Context) -> float:
    """Order the review queue. Never creates, removes or upgrades a flag."""
    if not flags:
        return 0.0
    severity = len({flag.feature for flag in flags})
    coverage = min(1.0, max(0.0, context.moderation_coverage))
    coverage_boost = 2.0 - coverage                      # fewer moderators: review sooner
    population_factor = 1.0 + min(context.population, 64) / 64   # more players affected
    off_hours = 1.25 if 0 <= context.hour_utc % 24 < 6 else 1.0
    return round(severity * coverage_boost * population_factor * off_hours, 3)
