import os
import tempfile
import unittest

from fastapi.testclient import TestClient

import api.database as database
from api.main import app

client = TestClient(app, raise_server_exceptions=False)
OPERATOR_HEADERS = {"X-API-Key": "dev-operator-key"}


class ScreeningHistoryContractTest(unittest.TestCase):
    """GET /screenings/{id} must return stored screening fields verbatim.

    sqlite3.Row iterates over values, so `key in row` is always False.
    Column-presence checks written that way silently return None for
    error_code, patient summary, model backend, and timings.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="drishti-hist-")
        self._orig_path = database.DB_PATH
        self._orig_done = database._init_done
        database.DB_PATH = os.path.join(self._tmp.name, "test.db")
        database._init_done = False
        self.patient_id = "PT-HIST-0001"
        response = client.post(
            "/patients",
            headers=OPERATOR_HEADERS,
            json={
                "patient_id": self.patient_id,
                "name": "History Probe",
                "age": 50,
                "gender": "Female",
                "phone": "9000000001",
                "village": "Test Village",
                "screening_centre": "PHC Test",
                "known_diabetes": "No",
                "physical_activity": "Moderate",
                "symptoms": [],
                "family_history": False,
            },
        )
        self.assertEqual(response.status_code, 201, response.text)

    def tearDown(self):
        database.DB_PATH = self._orig_path
        database._init_done = self._orig_done
        self._tmp.cleanup()

    def _save(self, **overrides):
        analysis = {
            "screening_id": "SCR-HIST-TEST",
            "patient_id": self.patient_id,
            "eye_side": "Right",
            "quality_grade": "BAD",
            "dr_grade": None,
            "dr_label": None,
            "requires_human_review": False,
            "patient_plain_language_summary": "Stored summary text.",
            "model_backend": "keras",
        }
        analysis.update(overrides)
        with database.get_db() as conn:
            database.save_screening_record(conn, analysis)

    def test_history_returns_error_code_and_stored_summary(self):
        self._save(
            screening_id="SCR-HIST-NOTFUNDUS",
            error_code="IMG_NOT_FUNDUS",
        )

        response = client.get(f"/screenings/{self.patient_id}", headers=OPERATOR_HEADERS)

        self.assertEqual(response.status_code, 200, response.text)
        rows = response.json()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["screening_id"], "SCR-HIST-NOTFUNDUS")
        self.assertEqual(row["error_code"], "IMG_NOT_FUNDUS")
        self.assertEqual(row["quality_grade"], "BAD")
        self.assertEqual(row["patient_plain_language_summary"], "Stored summary text.")
        self.assertEqual(row["model_backend"], "keras")
        # Ungradable screening: never fabricated as a healthy grade.
        self.assertIsNone(row["dr_grade"])
        self.assertIsNone(row["is_referable"])

    def test_history_returns_null_error_code_for_clean_screening(self):
        self._save(
            screening_id="SCR-HIST-CLEAN",
            quality_grade="GOOD",
            dr_grade=0,
            dr_label="No DR",
            is_referable=False,
            patient_plain_language_summary="No retinopathy detected.",
        )

        response = client.get(f"/screenings/{self.patient_id}", headers=OPERATOR_HEADERS)

        self.assertEqual(response.status_code, 200, response.text)
        row = response.json()[0]
        self.assertIsNone(row["error_code"])
        self.assertEqual(row["dr_grade"], 0)
        self.assertIs(row["is_referable"], False)

    def test_history_keeps_uncertain_grade_but_flags_low_confidence(self):
        self._save(
            screening_id="SCR-HIST-LOWCONF",
            quality_grade="GOOD",
            dr_grade=2,
            dr_label="Moderate NPDR",
            is_referable=True,
            error_code="AI_LOW_CONFIDENCE",
            requires_human_review=True,
            human_review_type="LOW_CONFIDENCE",
            human_review_reason="Confidence below threshold",
        )

        response = client.get(f"/screenings/{self.patient_id}", headers=OPERATOR_HEADERS)

        self.assertEqual(response.status_code, 200, response.text)
        row = response.json()[0]
        self.assertEqual(row["error_code"], "AI_LOW_CONFIDENCE")
        # Referable result stays visible for triage, but is never confident.
        self.assertEqual(row["dr_grade"], 2)
        self.assertIs(row["is_referable"], True)
        self.assertTrue(row["requires_human_review"])


if __name__ == "__main__":
    unittest.main()
