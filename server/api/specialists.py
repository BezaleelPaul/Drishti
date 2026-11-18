"""Specialist application records (read path for role mapping).

T3 needs one question answered: *is this email an approved specialist?*
The full application/approval workflow (T5–T7) builds on this module, so
the schema lives here from the start and is created idempotently.

Privacy: records contain professional-registration data, never patient
data. License documents are stored by reference only, never inline.
"""

from __future__ import annotations

import logging
import sqlite3
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

_SCHEMA = (
    "CREATE TABLE IF NOT EXISTS specialist_applications ("
    "id INTEGER PRIMARY KEY AUTOINCREMENT, "
    "email TEXT NOT NULL, "
    "full_name TEXT NOT NULL, "
    "council_reg_no TEXT NOT NULL, "
    "specialty TEXT NOT NULL, "
    "license_ref TEXT, "
    "status TEXT NOT NULL CHECK (status IN ('pending','approved','rejected')), "
    "submitted_at TEXT NOT NULL, "
    "decided_at TEXT, "
    "decided_by TEXT, "
    "decision_note TEXT)"
)

# One open application per email: the partial index is the concurrency-safe
# guard (T6 relies on it rather than a read-then-write race).
_OPEN_UNIQUE_INDEX = (
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_specialist_open_per_email "
    "ON specialist_applications(email) WHERE status = 'pending'"
)

_STATUS_INDEX = (
    "CREATE INDEX IF NOT EXISTS idx_specialist_status "
    "ON specialist_applications(status)"
)


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create the specialist tables/indexes idempotently on this connection."""
    conn.execute(_SCHEMA)
    conn.execute(_OPEN_UNIQUE_INDEX)
    conn.execute(_STATUS_INDEX)
    conn.commit()


def _normalise(email: str) -> str:
    return (email or "").strip().lower()


def status_for(email: str) -> str | None:
    """Current application status for an email, or None if there is none.

    Tolerates a database where the schema has not been created yet: role
    mapping must never fail because a fresh data directory exists.
    """
    normalised = _normalise(email)
    if not normalised:
        return None
    try:
        from api.database import get_connection

        conn = get_connection()
    except Exception as exc:  # noqa: BLE001 - role mapping must not crash auth
        logger.warning("specialist lookup unavailable: %s", exc)
        return None
    try:
        ensure_schema(conn)
        # An approved record wins over later rejected re-applications.
        row = conn.execute(
            "SELECT status FROM specialist_applications "
            "WHERE email = ? ORDER BY CASE status "
            "WHEN 'approved' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END, id DESC LIMIT 1",
            (normalised,),
        ).fetchone()
        return row["status"] if row else None
    except sqlite3.Error as exc:
        logger.warning("specialist lookup failed: %s", exc)
        return None
    finally:
        conn.close()


def submitted_at_now() -> str:
    """UTC ISO timestamp used for application records."""
    return datetime.now(timezone.utc).isoformat()
