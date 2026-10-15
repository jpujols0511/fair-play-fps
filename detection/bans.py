"""Confirmed outcomes. The only way in is a final human review decision signed
off by a moderator; detectors cannot write here. Confirmed rows become
labelled training data for the next calibration cycle."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import sqlite3


def subject_key(player_id: str) -> str:
    return hashlib.sha256(player_id.encode()).hexdigest()


class BanDatabase:
    def __init__(self, path: str = ":memory:"):
        self.db = sqlite3.connect(path)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS confirmed ("
            " case_id TEXT PRIMARY KEY, subject TEXT NOT NULL,"
            " outcome TEXT NOT NULL CHECK (outcome IN ('cheating', 'clean')),"
            " decided_at TEXT NOT NULL, features TEXT NOT NULL,"
            " reviewers INTEGER NOT NULL, moderator TEXT NOT NULL)")

    def record(self, decision, player_id: str, features: list[dict], moderator: str) -> None:
        if not decision.final or decision.outcome not in ("cheating", "clean"):
            raise PermissionError("only a final review decision can be recorded")
        if not moderator:
            raise PermissionError("a named moderator must sign off")
        self.db.execute(
            "INSERT INTO confirmed VALUES (?, ?, ?, ?, ?, ?, ?)",
            (decision.case_id, subject_key(player_id), decision.outcome,
             datetime.now(timezone.utc).isoformat(), json.dumps(features, sort_keys=True),
             len(decision.reviewers), moderator))
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def is_banned(self, player_id: str) -> bool:
        row = self.db.execute("SELECT 1 FROM confirmed WHERE subject = ? AND outcome = 'cheating'",
                              (subject_key(player_id),)).fetchone()
        return row is not None

    def training_rows(self) -> list[tuple[dict, bool]]:
        rows = self.db.execute("SELECT features, outcome FROM confirmed ORDER BY decided_at").fetchall()
        return [(window, outcome == "cheating") for features, outcome in rows for window in json.loads(features)]
