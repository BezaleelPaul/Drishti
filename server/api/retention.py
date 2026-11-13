"""Data-retention policy: purge screenings older than a configured window.

Disabled by default. Set ``RETENTION_DAYS`` (positive int) to enable, or
pass ``--days`` explicitly. Dry-run is the default; ``--apply`` deletes.

Deletes, for every screening with ``created_at`` older than the cutoff:
  - the ``screenings`` row + its ``doctor_reviews`` rows,
  - the ``results/api_screenings/<screening_id>/`` directory, if present,
  - the ``deid_screenings`` row + its stored image (Ticket C-4: the
    pseudonymized referral store purges on the SAME window — the doctor
    console is operational, not archival).

Patients, audit log, and sync receipts are NEVER deleted by this job
(patients outlive individual screenings; audit rows are the compliance
trail).
"""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any

RETENTION_DAYS_ENV = "RETENTION_DAYS"


def retention_days_from_env(default: int = 0) -> int:
    try:
        return max(0, int(os.environ.get(RETENTION_DAYS_ENV, default)))
    except (TypeError, ValueError):
        return default


def _parse_created(value: Any) -> datetime | None:
    if not value or not isinstance(value, str):
        return None
    try:
        v = value.strip()
        if v.endswith("Z"):
            v = v[:-1] + "+00:00"
        dt = datetime.fromisoformat(v)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def purge_expired_screenings(
    retention_days: int,
    db_path: str | None = None,
    results_dir: str | None = None,
    dry_run: bool = True,
) -> dict[str, Any]:
    """Purges screenings older than ``retention_days``. Returns a report dict."""
    if retention_days <= 0:
        raise ValueError("retention_days must be a positive integer.")
    from api import database as db

    db_path = db_path or db.DB_PATH
    if results_dir is None:
        results_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "results",
            "api_screenings",
        )
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    removed_screenings: list[str] = []
    removed_dirs: list[str] = []
    invalid_timestamps: list[str] = []
    removed_reviews = 0

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(screenings)")}
        if "screening_id" not in cols or "created_at" not in cols:
            note = "screenings table absent"
        else:
            note = None
            for row in conn.execute("SELECT screening_id, created_at FROM screenings"):
                created_at = _parse_created(row["created_at"])
                if created_at is None:
                    invalid_timestamps.append(row["screening_id"])
                elif created_at < cutoff:
                    removed_screenings.append(row["screening_id"])
            if not dry_run and removed_screenings:
                q = ",".join("?" for _ in removed_screenings)
                cur = conn.execute(
                    f"DELETE FROM doctor_reviews WHERE screening_id IN ({q})",
                    removed_screenings,
                )
                removed_reviews = cur.rowcount or 0
                conn.execute(
                    f"DELETE FROM screenings WHERE screening_id IN ({q})",
                    removed_screenings,
                )
                conn.commit()
            elif dry_run:
                ph = ",".join("?" for _ in removed_screenings)
                cur = (
                    conn.execute(
                        f"SELECT COUNT(*) FROM doctor_reviews WHERE screening_id IN ({ph})",
                        removed_screenings,
                    )
                    if removed_screenings
                    else None
                )
                removed_reviews = cur.fetchone()[0] if cur else 0
    finally:
        conn.close()

    for sid in removed_screenings:
        d = os.path.join(results_dir, sid)
        if os.path.isdir(d):
            removed_dirs.append(d)
            if not dry_run:
                shutil.rmtree(d, ignore_errors=True)

    # De-identified referral store (C-4): same retention window, image
    # files included. The doctor console is operational, not archival.
    removed_deid: list[str] = []
    deid_images_dir = os.path.join(results_dir, "deid_screenings")
    try:
        conn2 = sqlite3.connect(db_path)
        conn2.row_factory = sqlite3.Row
        try:
            cols = {r["name"] for r in conn2.execute("PRAGMA table_info(deid_screenings)")}
            if {"pseudo_screening_id", "created_at"} <= cols:
                for row in conn2.execute(
                    "SELECT pseudo_screening_id, image_path, created_at FROM deid_screenings"
                ):
                    created_at = _parse_created(row["created_at"])
                    if created_at is not None and created_at < cutoff:
                        removed_deid.append(row["pseudo_screening_id"])
                if not dry_run and removed_deid:
                    q = ",".join("?" for _ in removed_deid)
                    conn2.execute(
                        f"DELETE FROM deid_screenings WHERE pseudo_screening_id IN ({q})",
                        removed_deid,
                    )
                    conn2.commit()
        finally:
            conn2.close()
    except sqlite3.OperationalError:
        pass  # de-identified store not yet created; nothing to purge

    for pid in removed_deid:
        f = os.path.join(deid_images_dir, f"{pid}.jpg")
        if os.path.isfile(f) and not dry_run:
            try:
                os.remove(f)
            except OSError:
                pass

    return {
        "cutoff": cutoff.isoformat(),
        "screenings": removed_screenings,
        "reviews": removed_reviews,
        "dirs": removed_dirs,
        "deid": removed_deid,
        "invalid_timestamps": invalid_timestamps,
        "dry_run": dry_run,
        "note": note,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Purge expired screening records (dry-run default).")
    ap.add_argument(
        "--days",
        type=int,
        default=retention_days_from_env(),
        help="Retain screenings newer than DAYS. Also via RETENTION_DAYS.",
    )
    ap.add_argument("--apply", action="store_true", help="Actually delete (default: dry-run).")
    args = ap.parse_args()
    if args.days <= 0:
        print("retention disabled (days<=0); nothing to do.")
        return 0
    rep = purge_expired_screenings(args.days, dry_run=not args.apply)
    print(
        f"cutoff={rep['cutoff']} dry_run={rep['dry_run']} "
        f"screenings={len(rep['screenings'])} reviews={rep['reviews']} "
        f"dirs={len(rep['dirs'])} deid={len(rep['deid'])} "
        f"invalid_timestamps={len(rep['invalid_timestamps'])}"
    )
    for sid in rep["screenings"][:20]:
        print(f"  {sid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
