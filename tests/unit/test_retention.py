"""Tests for the data-retention purge job (api/retention.py)."""

import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from api.retention import _parse_created, purge_expired_screenings, retention_days_from_env

os.environ["SEED_DEMO_DATA"] = "0"


def _make_db(path: str, ages_days):
    """Creates a DB with one patient + screenings of given ages."""
    import api.database as db

    orig = db.DB_PATH
    db.DB_PATH = path
    try:
        db.init_db()
        conn = sqlite3.connect(path)
        try:
            conn.execute(
                "INSERT INTO patients (patient_id, name, age, gender, created_at) "
                "VALUES ('PT-T1', 'Test', 50, 'Male', ?)",
                (datetime.now(timezone.utc).isoformat(),),
            )
            for i, age in enumerate(ages_days):
                ts = (datetime.now(timezone.utc) - timedelta(days=age)).isoformat()
                conn.execute(
                    "INSERT INTO screenings (screening_id, patient_id, eye_side, quality_grade, created_at) "
                    "VALUES (?, 'PT-T1', 'Right', 'GOOD', ?)",
                    (f"SCR-T{i}", ts),
                )
            conn.commit()
        finally:
            conn.close()
    finally:
        db.DB_PATH = orig


class TestRetention(unittest.TestCase):
    def test_parse_created(self):
        self.assertIsNotNone(_parse_created(datetime.now(timezone.utc).isoformat()))
        self.assertIsNotNone(_parse_created("2026-01-01T00:00:00Z"))
        self.assertIsNotNone(_parse_created("2026-01-01T00:00:00"))
        self.assertIsNone(_parse_created(None))
        self.assertIsNone(_parse_created("garbage"))
        self.assertIsNone(_parse_created(123))

    def test_env_default(self):
        os.environ.pop("RETENTION_DAYS", None)
        self.assertEqual(retention_days_from_env(), 0)
        os.environ["RETENTION_DAYS"] = "abc"
        self.assertEqual(retention_days_from_env(), 0)
        os.environ["RETENTION_DAYS"] = "365"
        self.assertEqual(retention_days_from_env(), 365)
        del os.environ["RETENTION_DAYS"]

    def test_rejects_nonpositive(self):
        with self.assertRaises(ValueError):
            purge_expired_screenings(0)

    def test_invalid_timestamps_are_reported_and_not_purged(self):
        with tempfile.TemporaryDirectory() as td:
            dbp = os.path.join(td, "t.db")
            _make_db(dbp, [400])
            conn = sqlite3.connect(dbp)
            try:
                conn.execute(
                    "INSERT INTO screenings "
                    "(screening_id, patient_id, eye_side, quality_grade, created_at) "
                    "VALUES ('SCR-BAD', 'PT-T1', 'Right', 'GOOD', 'not-a-timestamp')"
                )
                conn.commit()
            finally:
                conn.close()

            report = purge_expired_screenings(365, db_path=dbp, dry_run=True)

            self.assertEqual(report["screenings"], ["SCR-T0"])
            self.assertEqual(report["invalid_timestamps"], ["SCR-BAD"])

    def test_dry_run_deletes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            dbp = os.path.join(td, "t.db")
            rdir = os.path.join(td, "res")
            os.makedirs(os.path.join(rdir, "SCR-T0"))
            _make_db(dbp, [400, 10])
            rep = purge_expired_screenings(365, db_path=dbp, results_dir=rdir, dry_run=True)
            self.assertEqual(rep["screenings"], ["SCR-T0"])
            self.assertEqual(rep["dirs"], [os.path.join(rdir, "SCR-T0")])
            self.assertTrue(os.path.isdir(os.path.join(rdir, "SCR-T0")))
            conn = sqlite3.connect(dbp)
            try:
                n = conn.execute("SELECT COUNT(*) FROM screenings").fetchone()[0]
            finally:
                conn.close()
            self.assertEqual(n, 2)

    def test_apply_deletes_old_only(self):
        with tempfile.TemporaryDirectory() as td:
            dbp = os.path.join(td, "t.db")
            rdir = os.path.join(td, "res")
            os.makedirs(os.path.join(rdir, "SCR-T0"))
            _make_db(dbp, [400, 10])
            rep = purge_expired_screenings(365, db_path=dbp, results_dir=rdir, dry_run=False)
            self.assertFalse(rep["dry_run"])
            self.assertEqual(rep["screenings"], ["SCR-T0"])
            self.assertFalse(os.path.exists(os.path.join(rdir, "SCR-T0")))
            conn = sqlite3.connect(dbp)
            try:
                rows = [r[0] for r in conn.execute("SELECT screening_id FROM screenings")]
                pats = conn.execute("SELECT COUNT(*) FROM patients").fetchone()[0]
            finally:
                conn.close()
            self.assertEqual(rows, ["SCR-T1"])
            self.assertEqual(pats, 1)  # patients never purged

    def test_deid_store_purged_on_same_window_with_images(self):
        with tempfile.TemporaryDirectory() as td:
            dbp = os.path.join(td, "t.db")
            rdir = os.path.join(td, "res")
            _make_db(dbp, [400, 10])
            deid_dir = os.path.join(rdir, "deid_screenings")
            os.makedirs(deid_dir)
            old_img = os.path.join(deid_dir, "SCR-OLD1.jpg")
            new_img = os.path.join(deid_dir, "SCR-NEW1.jpg")
            for name in ("SCR-OLD1.jpg", "SCR-NEW1.jpg"):
                with open(os.path.join(deid_dir, name), "wb") as fh:
                    fh.write(b"\xff\xd8fakejpeg")
            old_ts = (datetime.now(timezone.utc) - timedelta(days=400)).isoformat()
            new_ts = datetime.now(timezone.utc).isoformat()
            conn = sqlite3.connect(dbp)
            try:
                conn.execute(
                    "INSERT INTO deid_screenings "
                    "(pseudo_screening_id, pseudonym, eye_side, consent_version, "
                    " image_path, created_at) "
                    "VALUES ('SCR-OLD1', 'RSV-AAAA0001', 'Right', 'v1-2026-09', ?, ?)",
                    (old_img, old_ts),
                )
                conn.execute(
                    "INSERT INTO deid_screenings "
                    "(pseudo_screening_id, pseudonym, eye_side, consent_version, "
                    " image_path, created_at) "
                    "VALUES ('SCR-NEW1', 'RSV-BBBB0002', 'Left', 'v1-2026-09', ?, ?)",
                    (new_img, new_ts),
                )
                conn.commit()
            finally:
                conn.close()

            rep = purge_expired_screenings(365, db_path=dbp, results_dir=rdir, dry_run=True)
            self.assertEqual(rep["deid"], ["SCR-OLD1"])
            self.assertTrue(os.path.isfile(old_img))  # dry-run: file untouched

            rep = purge_expired_screenings(365, db_path=dbp, results_dir=rdir, dry_run=False)
            self.assertEqual(rep["deid"], ["SCR-OLD1"])
            self.assertFalse(os.path.exists(old_img))
            self.assertTrue(os.path.isfile(new_img))  # fresh row + image kept
            conn = sqlite3.connect(dbp)
            try:
                ids = [
                    r[0] for r in conn.execute("SELECT pseudo_screening_id FROM deid_screenings")
                ]
            finally:
                conn.close()
            self.assertEqual(ids, ["SCR-NEW1"])


if __name__ == "__main__":
    unittest.main()
