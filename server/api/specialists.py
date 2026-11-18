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
from datetime import datetime, timedelta, timezone

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


# --------------------------------------------------------------------------- #
# Application workflow (T5-T7)
# --------------------------------------------------------------------------- #
#: A rejected applicant may re-apply after this many days (spec R5.5).
RESUBMIT_COOLDOWN_DAYS = 7


class SpecialistError(RuntimeError):
    """Base for workflow errors. ``code`` is a stable machine-readable key."""

    code = "specialist_error"


class AlreadyApprovedError(SpecialistError):
    code = "already_approved"


class DuplicatePendingError(SpecialistError):
    code = "duplicate_pending"


class CooldownError(SpecialistError):
    code = "cooldown_active"

    def __init__(self, retry_at: str) -> None:
        super().__init__(f"resubmission available after {retry_at}")
        self.retry_at = retry_at


class ApplicationNotFoundError(SpecialistError):
    code = "not_found"


class ApplicationStateError(SpecialistError):
    code = "invalid_state"


def _row_to_dict(row: sqlite3.Row) -> dict:
    return {key: row[key] for key in row.keys()}


def latest_for_email(email: str) -> dict | None:
    """Latest application record for an email (any status)."""
    normalised = _normalise(email)
    if not normalised:
        return None
    from api.database import get_connection

    conn = get_connection()
    try:
        ensure_schema(conn)
        row = conn.execute(
            "SELECT * FROM specialist_applications WHERE email = ? ORDER BY id DESC LIMIT 1",
            (normalised,),
        ).fetchone()
        return _row_to_dict(row) if row else None
    finally:
        conn.close()


def _cooldown_retry_at(row: dict | None) -> str | None:
    """ISO timestamp when re-application is allowed, or None if allowed now."""
    if not row or row.get("status") != "rejected" or not row.get("decided_at"):
        return None
    try:
        decided = datetime.fromisoformat(str(row["decided_at"]).replace("Z", "+00:00"))
    except ValueError:
        return None
    if decided.tzinfo is None:
        decided = decided.replace(tzinfo=timezone.utc)
    retry_at = decided + timedelta(days=RESUBMIT_COOLDOWN_DAYS)
    now = datetime.now(timezone.utc)
    return retry_at.isoformat() if retry_at > now else None


def apply_for_specialist(
    email: str,
    full_name: str,
    council_reg_no: str,
    specialty: str,
    license_ref: str | None = None,
) -> dict:
    """Create a pending application, enforcing the workflow invariants.

    Raises :class:`AlreadyApprovedError`, :class:`DuplicatePendingError` or
    :class:`CooldownError` with stable codes. The partial unique index is the
    final concurrency guard; the pre-checks exist to return honest messages.
    """
    normalised = _normalise(email)
    if not normalised:
        raise ValueError("a verified email is required")
    latest = latest_for_email(normalised)
    if latest and latest["status"] == "approved":
        raise AlreadyApprovedError("this account is already an approved specialist")
    if latest and latest["status"] == "pending":
        raise DuplicatePendingError("an application is already awaiting review")
    retry_at = _cooldown_retry_at(latest)
    if retry_at:
        raise CooldownError(retry_at)

    from api.database import get_connection

    conn = get_connection()
    try:
        ensure_schema(conn)
        cursor = conn.execute(
            "INSERT INTO specialist_applications "
            "(email, full_name, council_reg_no, specialty, license_ref, status, submitted_at) "
            "VALUES (?, ?, ?, ?, ?, 'pending', ?)",
            (
                normalised,
                full_name.strip(),
                council_reg_no.strip(),
                specialty.strip(),
                (license_ref or "").strip() or None,
                submitted_at_now(),
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM specialist_applications WHERE id = ?", (cursor.lastrowid,)
        ).fetchone()
        return _row_to_dict(row)
    except sqlite3.IntegrityError as exc:
        # Lost a race against the partial unique index.
        raise DuplicatePendingError("an application is already awaiting review") from exc
    finally:
        conn.close()


def list_applications(status: str | None = None) -> list[dict]:
    """Applications, newest first, optionally filtered by status."""
    from api.database import get_connection

    conn = get_connection()
    try:
        ensure_schema(conn)
        if status:
            rows = conn.execute(
                "SELECT * FROM specialist_applications WHERE status = ? ORDER BY id DESC",
                (status,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM specialist_applications ORDER BY id DESC"
            ).fetchall()
        return [_row_to_dict(row) for row in rows]
    finally:
        conn.close()


def decide_application(application_id: int, approve: bool, actor: str, note: str = "") -> dict:
    """Approve or reject a pending application (admin action).

    Only a *pending* record can be decided — decisions are not silently
    re-applied to closed records.
    """
    from api.database import get_connection

    conn = get_connection()
    try:
        ensure_schema(conn)
        row = conn.execute(
            "SELECT * FROM specialist_applications WHERE id = ?", (application_id,)
        ).fetchone()
        if row is None:
            raise ApplicationNotFoundError("application not found")
        if row["status"] != "pending":
            raise ApplicationStateError("only pending applications can be decided")
        conn.execute(
            "UPDATE specialist_applications SET status = ?, decided_at = ?, "
            "decided_by = ?, decision_note = ? WHERE id = ?",
            (
                "approved" if approve else "rejected",
                submitted_at_now(),
                actor,
                (note or "").strip()[:500] or None,
                application_id,
            ),
        )
        conn.commit()
        updated = conn.execute(
            "SELECT * FROM specialist_applications WHERE id = ?", (application_id,)
        ).fetchone()
        return _row_to_dict(updated)
    finally:
        conn.close()
