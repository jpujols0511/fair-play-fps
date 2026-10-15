"""Offline fair-play detection.

Runs on recorded demos after a match, never inside the live server
(invariant 5). Produces explainable flags that order a human review queue.
A flag is a reason to review, never a verdict (invariant 6).
"""
import sys
from pathlib import Path

_PROTOTYPE = Path(__file__).resolve().parents[1] / "prototype"
if str(_PROTOTYPE) not in sys.path:
    sys.path.insert(0, str(_PROTOTYPE))
