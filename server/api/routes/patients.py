from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query

from api.auth import ApiPrincipal, audit_action, require_auth
from api.database import get_db
from api.schemas import PatientCreate, PatientListResponse, PatientResponse

router = APIRouter(prefix="/patients", tags=["Patients"])


@router.post("", response_model=PatientResponse, status_code=201)
def register_patient(payload: PatientCreate, _principal: ApiPrincipal = Depends(require_auth)):
    with get_db() as conn:
        cursor = conn.cursor()

        patient_id = payload.patient_id or f"PT-2026-{uuid.uuid4().hex[:4].upper()}"
        now = datetime.now(timezone.utc).isoformat()

        # Check for duplicate (fast path). The INSERT below is additionally
        # guarded: two concurrent registrations with the same id must 409,
        # not 500 on an uncaught IntegrityError.
        cursor.execute("SELECT patient_id FROM patients WHERE patient_id = ?", (patient_id,))
        if cursor.fetchone():
            raise HTTPException(
                status_code=409, detail=f"Patient ID {patient_id} already registered."
            )

        try:
            cursor.execute(
                """
        INSERT INTO patients (
            patient_id, abha_id, name, age, gender, phone, village, screening_centre,
            known_diabetes, diabetes_duration_years, hba1c, fasting_glucose, blood_pressure,
            bmi, family_history, physical_activity, symptoms, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
                (
                    patient_id,
                    payload.abha_id,
                    payload.name,
                    payload.age,
                    payload.gender,
                    payload.phone,
                    payload.village,
                    payload.screening_centre,
                    payload.known_diabetes,
                    payload.diabetes_duration_years,
                    payload.hba1c,
                    payload.fasting_glucose,
                    payload.blood_pressure,
                    payload.bmi,
                    1 if payload.family_history else 0,
                    payload.physical_activity,
                    json.dumps(payload.symptoms),
                    now,
                ),
            )
        except sqlite3.IntegrityError:
            raise HTTPException(
                status_code=409, detail=f"Patient ID {patient_id} already registered."
            )
        conn.commit()

    return PatientResponse(
        patient_id=patient_id,
        name=payload.name,
        age=payload.age,
        gender=payload.gender,
        phone=payload.phone,
        abha_id=payload.abha_id,
        village=payload.village,
        screening_centre=payload.screening_centre,
        known_diabetes=payload.known_diabetes,
        diabetes_duration_years=payload.diabetes_duration_years,
        hba1c=payload.hba1c,
        fasting_glucose=payload.fasting_glucose,
        blood_pressure=payload.blood_pressure,
        bmi=payload.bmi,
        family_history=payload.family_history,
        physical_activity=payload.physical_activity,
        symptoms=payload.symptoms,
        created_at=now,
    )


def _safe_symptoms(value) -> list:
    """Parse symptoms JSON column; [] on NULL/garbage instead of 500."""
    if not value:
        return []
    if isinstance(value, list):
        return value
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, list) else []
    except (json.JSONDecodeError, TypeError):
        return []


@router.get("", response_model=PatientListResponse)
def list_patients(
    search: str | None = Query(None, max_length=64, description="Search by name, ID, or ABHA"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    _principal: ApiPrincipal = Depends(require_auth),
):
    with get_db() as conn:
        cursor = conn.cursor()

        if search:
            # Escape LIKE wildcards so '%'/'_' are literal, and cap length.
            escaped = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            pattern = f"%{escaped}%"
            cursor.execute(
                """
            SELECT * FROM patients
            WHERE name LIKE ? ESCAPE '\\' OR patient_id LIKE ? ESCAPE '\\'
               OR abha_id LIKE ? ESCAPE '\\' OR phone LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
                (pattern, pattern, pattern, pattern, limit, offset),
            )
        else:
            cursor.execute(
                "SELECT * FROM patients ORDER BY created_at DESC LIMIT ? OFFSET ?", (limit, offset)
            )

        rows = cursor.fetchall()
        # Total across ALL pages with the same filter (not len(page)), or
        # client pagination ("showing X of Y") can never advance.
        if search:
            cursor.execute(
                """
            SELECT COUNT(*) as total FROM patients
            WHERE name LIKE ? ESCAPE '\\' OR patient_id LIKE ? ESCAPE '\\'
               OR abha_id LIKE ? ESCAPE '\\' OR phone LIKE ? ESCAPE '\\'
            """,
                (pattern, pattern, pattern, pattern),
            )
        else:
            cursor.execute("SELECT COUNT(*) as total FROM patients")
        total = cursor.fetchone()["total"]

    patients = []
    for r in rows:
        patients.append(
            PatientResponse(
                patient_id=r["patient_id"],
                name=r["name"],
                age=r["age"],
                gender=r["gender"],
                phone=r["phone"],
                abha_id=r["abha_id"],
                village=r["village"],
                screening_centre=r["screening_centre"],
                known_diabetes=r["known_diabetes"],
                diabetes_duration_years=r["diabetes_duration_years"],
                hba1c=r["hba1c"],
                fasting_glucose=r["fasting_glucose"],
                blood_pressure=r["blood_pressure"],
                bmi=r["bmi"],
                family_history=bool(r["family_history"]),
                physical_activity=r["physical_activity"],
                symptoms=_safe_symptoms(r["symptoms"]),
                created_at=r["created_at"],
            )
        )

    # One audit row per LIST call (never per row): the compliance trail
    # records who enumerated PHI without flooding the log.
    audit_action(
        _principal,
        "patient_list",
        f"search={'set' if search else '-'} returned={len(patients)} total={total}",
    )
    return PatientListResponse(total=total, patients=patients)


@router.get("/{patient_id}", response_model=PatientResponse)
def get_patient(patient_id: str, _principal: ApiPrincipal = Depends(require_auth)):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM patients WHERE patient_id = ?", (patient_id,))
        r = cursor.fetchone()

    if not r:
        raise HTTPException(status_code=404, detail=f"Patient {patient_id} not found.")

    audit_action(_principal, "patient_read", patient_id)

    return PatientResponse(
        patient_id=r["patient_id"],
        name=r["name"],
        age=r["age"],
        gender=r["gender"],
        phone=r["phone"],
        abha_id=r["abha_id"],
        village=r["village"],
        screening_centre=r["screening_centre"],
        known_diabetes=r["known_diabetes"],
        diabetes_duration_years=r["diabetes_duration_years"],
        hba1c=r["hba1c"],
        fasting_glucose=r["fasting_glucose"],
        blood_pressure=r["blood_pressure"],
        bmi=r["bmi"],
        family_history=bool(r["family_history"]),
        physical_activity=r["physical_activity"],
        symptoms=_safe_symptoms(r["symptoms"]),
        created_at=r["created_at"],
    )
