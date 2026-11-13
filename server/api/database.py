"""
Lightweight SQLite persistence layer for Netra-AI.
Stores patients, screening records, and doctor review actions.
Fully offline-first and portable across platforms.
"""

from __future__ import annotations

import json
import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any


def _resolve_db_path(raw: str) -> str:
    """DRISHTI_DB_PATH accepts a directory (db file created inside) or a
    file path (used directly). The old check only recognized *existing*
    files, so a fresh file path was mkdir'd into a directory of that name.
    Suffix + parent semantics decide for not-yet-existing paths."""
    candidate = (raw or "").strip()
    if not candidate:
        fallback = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "data",
        )
        os.makedirs(fallback, exist_ok=True)
        return os.path.join(fallback, "screening_platform.db")
    if os.path.isdir(candidate):
        return os.path.join(candidate, "screening_platform.db")
    if os.path.isfile(candidate):
        return candidate
    if candidate.lower().endswith((".db", ".sqlite", ".sqlite3", ".db3")):
        parent = os.path.dirname(os.path.abspath(candidate))
        os.makedirs(parent, exist_ok=True)
        return os.path.abspath(candidate)
    os.makedirs(candidate, exist_ok=True)
    return os.path.join(candidate, "screening_platform.db")


_DB_DIR = os.environ.get(
    "DRISHTI_DB_PATH",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"),
)
DB_PATH = _resolve_db_path(_DB_DIR)


def get_connection() -> sqlite3.Connection:
    """Concurrency-hardened SQLite connection: WAL mode, busy timeouts,
    FK enforcement. Callers must still keep transactions short and never
    hold a connection across model inference."""
    conn = sqlite3.connect(DB_PATH, timeout=30.0, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


@contextmanager
def get_db():
    """Context manager ensuring connections are closed; rolls back any
    half-finished transaction on error instead of leaking it."""
    ensure_db()
    conn = get_connection()
    try:
        yield conn
    except Exception:
        try:
            conn.rollback()
        except sqlite3.Error:
            pass
        raise
    finally:
        conn.close()


def save_screening_record(conn: sqlite3.Connection, analysis: dict[str, Any]) -> str:
    """
    Persists screening record and enrolls into doctor review queue if flagged.
    Guarantees zero data loss between direct API and offline batch sync.
    """
    for required in ("screening_id", "patient_id"):
        if not analysis.get(required):
            raise ValueError(f"Cannot persist screening: missing required key '{required}'.")
    is_ref = analysis.get("is_referable")
    cursor = conn.cursor()
    cursor.execute(
        """
    INSERT INTO screenings (
        screening_id, patient_id, eye_side, camera_profile, quality_grade,
        quality_score, rejection_reasons, suspected_clinical_cause,
        dr_grade_num, dr_grade_label, dr_confidence, is_referable,
        requires_human_review, human_review_type, human_review_reason,
        original_image_path, gradcam_overlay_path, target_layer,
        action_recommendation, screening_status, created_at,
        probabilities, vessel_density_pct, microaneurysm_count, csme_risk,
        min_fovea_distance_px, confidence_flags, patient_summary, captured_at,
        model_backend, inference_time_ms, error_code
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
        (
            analysis["screening_id"],
            analysis["patient_id"],
            analysis.get("eye_side", "Right"),
            analysis.get("camera_profile", "Generic Fundus Camera"),
            analysis.get("quality_grade", "GOOD"),
            analysis.get("quality_score", 0.0),
            json.dumps(analysis.get("rejection_reasons", [])),
            analysis.get("suspected_clinical_cause"),
            analysis.get("dr_grade"),
            analysis.get("dr_label"),
            analysis.get("prediction_score"),
            None if is_ref is None else (1 if is_ref else 0),
            1 if analysis.get("requires_human_review") else 0,
            analysis.get("human_review_type"),
            analysis.get("human_review_reason"),
            analysis.get("original_image_url"),
            analysis.get("gradcam_overlay_url"),
            analysis.get("gradcam_target_layer"),
            analysis.get("action_recommendation", ""),
            "Completed",
            analysis.get("created_at", datetime.now(timezone.utc).isoformat()),
            json.dumps(analysis.get("probabilities"))
            if analysis.get("probabilities") is not None
            else None,
            analysis.get("vessel_density_pct"),
            analysis.get("microaneurysm_count"),
            analysis.get("csme_risk"),
            analysis.get("min_fovea_distance_px"),
            json.dumps(analysis.get("confidence_flags", [])),
            analysis.get("patient_plain_language_summary"),
            analysis.get("captured_at"),
            analysis.get("model_backend", "unknown"),
            analysis.get("inference_time_ms"),
            analysis.get("error_code"),
        ),
    )

    # If human review required, create pending doctor review queue item.
    # Plain INSERT with retry: a dropped review (OR IGNORE) would silently lose
    # a flagged case, so collisions must raise/retry, never be swallowed.
    if analysis.get("requires_human_review"):
        import sqlite3 as _sqlite3

        for _attempt in range(3):
            review_id = f"REV-{uuid.uuid4().hex[:12].upper()}"
            try:
                cursor.execute(
                    """
                INSERT INTO doctor_reviews (
                    review_id, screening_id, patient_id, status, created_at
                ) VALUES (?, ?, ?, 'PENDING', ?)
                """,
                    (
                        review_id,
                        analysis["screening_id"],
                        analysis["patient_id"],
                        analysis.get("created_at", datetime.now(timezone.utc).isoformat()),
                    ),
                )
                break
            except _sqlite3.IntegrityError:
                if _attempt == 2:
                    raise

    conn.commit()
    return analysis["screening_id"]


def init_db():
    """Initializes schema and pre-populates demo rural patients if empty."""
    # Uses get_connection() directly (NOT get_db()): get_db() calls
    # ensure_db(), which calls init_db() — going through get_db() here was
    # the recursion that forced the set-flag-first race in ensure_db().
    conn = get_connection()
    try:
        cursor = conn.cursor()

        # 1. Patients Table
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS patients (
            patient_id TEXT PRIMARY KEY,
            abha_id TEXT,
            name TEXT NOT NULL,
            age INTEGER NOT NULL,
            gender TEXT NOT NULL,
            phone TEXT,
            village TEXT,
            screening_centre TEXT,
            known_diabetes TEXT DEFAULT 'Unknown',
            diabetes_duration_years REAL,
            hba1c REAL,
            fasting_glucose REAL,
            blood_pressure TEXT,
            bmi REAL,
            family_history BOOLEAN DEFAULT 0,
            physical_activity TEXT DEFAULT 'Moderate',
            symptoms TEXT DEFAULT '[]',
            created_at TEXT NOT NULL
        )
        """)

        # 2. Retinal Screenings Table
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS screenings (
            screening_id TEXT PRIMARY KEY,
            patient_id TEXT NOT NULL,
            eye_side TEXT NOT NULL,          -- 'Right' or 'Left'
            camera_profile TEXT DEFAULT 'Generic Fundus Camera',
            quality_grade TEXT NOT NULL,    -- 'GOOD', 'BORDERLINE', 'BAD'
            quality_score REAL,
            rejection_reasons TEXT,         -- JSON array
            suspected_clinical_cause TEXT,
            recapture_instructions TEXT,
            dr_grade_num INTEGER,           -- 0 to 4
            dr_grade_label TEXT,
            dr_confidence REAL,
            is_referable BOOLEAN DEFAULT 0,
            requires_human_review BOOLEAN DEFAULT 0,
            human_review_type TEXT,
            human_review_reason TEXT,
            original_image_path TEXT,
            gradcam_overlay_path TEXT,
            target_layer TEXT,
             action_recommendation TEXT,
             screening_status TEXT DEFAULT 'Completed',
            model_backend TEXT DEFAULT 'unknown',
            inference_time_ms REAL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(patient_id) REFERENCES patients(patient_id)
        )
        """)

        # 3. Doctor Review Queue & Decisions Table
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS doctor_reviews (
            review_id TEXT PRIMARY KEY,
            screening_id TEXT NOT NULL,
            patient_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'PENDING', -- 'PENDING', 'CONFIRMED', 'OVERRIDDEN', 'REFERRED', 'RECAPTURE_REQUESTED'
            doctor_name TEXT,
            doctor_decision TEXT,
            doctor_grade_override INTEGER,
            clinical_notes TEXT,
            referral_urgency TEXT,
            follow_up_days INTEGER,
            created_at TEXT NOT NULL,
            reviewed_at TEXT,
            FOREIGN KEY(screening_id) REFERENCES screenings(screening_id),
            FOREIGN KEY(patient_id) REFERENCES patients(patient_id)
        )
        """)

        # 4. Audit Log (auth failures, verdicts, overrides — append-only)
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            resource TEXT NOT NULL,
            detail TEXT,
            created_at TEXT NOT NULL
        )
        """)
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at)")

        # Sync idempotency receipts: maps client local_screening_id -> server
        # screening_id. Retried offline batches replay without re-running
        # inference or minting duplicate rows (PK = dedup key).
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS sync_receipts (
            local_screening_id TEXT PRIMARY KEY,
            screening_id TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """)

        # De-identified sync store (/sync/v2, Ticket C-4): pseudonym-keyed
        # screening results with NO PHI columns — name/phone/ABHA/village do
        # not exist as fields, and the fail-closed linter rejects payloads
        # that try to smuggle them in. The row's PK doubles as the sync
        # receipt (INSERT OR IGNORE + fetch = idempotent replay).
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS deid_screenings (
            pseudo_screening_id TEXT PRIMARY KEY,
            pseudonym TEXT NOT NULL,
            age_band TEXT,
            gender TEXT,
            eye_side TEXT NOT NULL CHECK (eye_side IN ('Right','Left')),
            dr_grade_num INTEGER CHECK (dr_grade_num IS NULL OR dr_grade_num BETWEEN 0 AND 4),
            dr_label TEXT,
            prob_vector TEXT,
            confidence REAL,
            requires_human_review INTEGER NOT NULL DEFAULT 0,
            consent_version TEXT NOT NULL,
            image_path TEXT,
            captured_at TEXT,
            created_at TEXT NOT NULL
        )
        """)
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_deid_pseudonym ON deid_screenings(pseudonym, created_at)"
        )

        # Lookup indexes (avoid full-table scans as screening volume grows)
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_screenings_patient ON screenings(patient_id, created_at)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_screenings_created ON screenings(created_at)"
        )
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_patients_created ON patients(created_at)")
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_reviews_status ON doctor_reviews(status, created_at)"
        )
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_patients_abha ON patients(abha_id)")

        # Column migration for databases created before the biomarker fields
        # existed: CREATE TABLE IF NOT EXISTS never adds columns, so backfill
        # them idempotently here (existing rows keep NULL = unassessed).
        _ensure_screening_columns(cursor)

        # Check if demo seed data exists
        cursor.execute("SELECT COUNT(*) as count FROM patients")
        if cursor.fetchone()["count"] == 0 and _seeding_allowed():
            import logging as _logging

            _logging.getLogger(__name__).warning(
                "Seeding DEMO patient data (ENV=%s). Never rely on this in "
                "production; set SEED_DEMO_DATA=0 to disable.",
                os.environ.get("ENV", "dev"),
            )
            _seed_demo_data(cursor)

        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except sqlite3.Error:
            pass
        raise
    finally:
        conn.close()


def _ensure_screening_columns(cursor: sqlite3.Cursor) -> None:
    """Idempotent migration: older screenings tables lack the biomarker /
    summary columns that GET /screenings/{id} now returns verbatim instead
    of fabricating. PRAGMA-gated so re-runs and concurrent boots are safe."""
    existing = {row["name"] for row in cursor.execute("PRAGMA table_info(screenings)")}
    for name, ddl in (
        ("probabilities", "TEXT"),
        ("vessel_density_pct", "REAL"),
        ("microaneurysm_count", "INTEGER"),
        ("csme_risk", "TEXT"),
        ("min_fovea_distance_px", "REAL"),
        ("confidence_flags", "TEXT"),
        ("patient_summary", "TEXT"),
        ("captured_at", "TEXT"),
        ("model_backend", "TEXT"),
        ("inference_time_ms", "REAL"),
        ("error_code", "TEXT"),
    ):
        if name not in existing:
            cursor.execute(f"ALTER TABLE screenings ADD COLUMN {name} {ddl}")


def _seeding_allowed() -> bool:
    """Demo PHI must never pollute a production database. Seeds run only in
    non-prod (unless explicitly disabled), or in prod when explicitly opted
    in via SEED_DEMO_DATA=1."""
    env = os.environ.get("ENV", "dev").lower()
    flag = os.environ.get("SEED_DEMO_DATA")
    if env == "prod":
        return flag == "1"
    return flag != "0"


def _seed_demo_data(cursor: sqlite3.Cursor):
    # OR IGNORE: multi-worker boot may race here; fixed PKs make re-runs safe.
    now = datetime.now(timezone.utc).isoformat()
    sample_patients = [
        (
            "PT-2026-101",
            "91-4521-8890-3321",
            "Ramesh Kumar",
            54,
            "Male",
            "+91 98451 22340",
            "Shivaji Nagar, PHC Bhor",
            "Bhor Rural Health Sub-Centre",
            "Yes",
            6.0,
            8.2,
            165.0,
            "138/86",
            28.4,
            1,
            "Sedentary",
            json.dumps(["Blurry vision", "Mild fatigue"]),
            now,
        ),
        (
            "PT-2026-102",
            "91-7712-4402-9981",
            "Sunita Devi",
            48,
            "Female",
            "+91 94210 55123",
            "Khed Village, PHC Khed",
            "Khed Community Health Centre",
            "No",
            0.0,
            6.2,
            110.0,
            "122/80",
            25.1,
            1,
            "Moderate",
            json.dumps(["Mild fatigue"]),
            now,
        ),
        (
            "PT-2026-103",
            "91-2309-1144-6677",
            "Anand Patil",
            62,
            "Male",
            "+91 97633 11890",
            "Wadgaon, Mobile Van #2",
            "Western Ghats Screening Van",
            "Yes",
            12.0,
            9.4,
            210.0,
            "145/92",
            30.2,
            1,
            "Sedentary",
            json.dumps(["Blurry vision", "Frequent urination", "Dark spots in vision"]),
            now,
        ),
    ]
    cursor.executemany(
        """
    INSERT OR IGNORE INTO patients (
        patient_id, abha_id, name, age, gender, phone, village, screening_centre,
        known_diabetes, diabetes_duration_years, hba1c, fasting_glucose, blood_pressure,
        bmi, family_history, physical_activity, symptoms, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
        sample_patients,
    )


import threading as _threading

_init_lock = _threading.Lock()
_init_done = False


def ensure_db() -> None:
    """Idempotent, race-safe schema init. Called from the app lifespan and
    lazily from get_db() so bare TestClient usage (no lifespan) still works.

    The done-flag is set only AFTER init_db() succeeds: a concurrent caller
    either waits on the lock or sees a fully-initialized database. (Multi-
    process boot additionally relies on CREATE TABLE IF NOT EXISTS +
    busy_timeout + OR IGNORE seeds, since the flag is per-process.)
    """
    global _init_done
    if _init_done:
        return
    with _init_lock:
        if _init_done:
            return
        init_db()
        _init_done = True
