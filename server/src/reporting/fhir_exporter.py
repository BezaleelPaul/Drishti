"""
FHIR R4 DiagnosticReport & Observation Exporter for ABDM (Ayushman Bharat Digital Mission).
Standardized clinical JSON schema for national tele-retinal health interoperability.
"""

import re
import uuid
from datetime import datetime, timezone
from typing import Any


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def export_abdm_fhir_diagnostic_report(
    patient_data: dict[str, Any],
    screening_record: Any,
    biomarkers: dict[str, Any],
    doctor_name: str = "Dr. S. Ramanathan, MD (Ophthal)",
    doctor_action: str = "Routine Annual Rescreening",
) -> dict[str, Any]:
    """
    Generates an HL7 FHIR R4 compliant DiagnosticReport resource with embedded Observations.
    Conforms to Indian ABDM / Ayushman Bharat Digital Mission tele-ophthalmology guidelines.
    """
    patient_id = patient_data.get("patient_id", "ABHA-0000-0000-0000")
    biomarkers = biomarkers or {}
    now = datetime.now(timezone.utc)
    timestamp = now.isoformat().replace("+00:00", "Z")

    # Sanitize patient_id for FHIR id / reference (FHIR id: [A-Za-z0-9\-\.]{1,64}).
    raw_pid = str(patient_id) if patient_id is not None else ""
    sanitized_pid = re.sub(r"[^A-Za-z0-9\-\.]", "-", raw_pid)[:64].strip("-").strip(".")
    if not sanitized_pid or not sanitized_pid.strip("-."):
        sanitized_pid = f"patient-{uuid.uuid4().hex[:8]}"
    # Unique resource id to avoid same-second collisions; keep within 64 chars.
    raw_resource_id = f"dr-screening-{sanitized_pid}-{int(now.timestamp())}-{uuid.uuid4().hex[:8]}"
    resource_id = re.sub(r"[^A-Za-z0-9\-\.]", "-", raw_resource_id)[:64].strip("-").strip(".")
    if not resource_id:
        resource_id = f"dr-screening-{uuid.uuid4().hex[:16]}"

    dr_pred = getattr(screening_record, "dr_prediction", None)
    if dr_pred:
        grade_num = dr_pred.predicted_grade.value
        grade_label = dr_pred.predicted_grade.label
        confidence = float(dr_pred.confidence)
        referable = grade_num >= 2
    else:
        grade_num = None
        grade_label = "Ungradable / Image Rejected"
        confidence = 0.0
        referable = False

    # SNOMED CT Codes for Diabetic Retinopathy
    snomed_system = "http://snomed.info/sct"
    snomed_codes = {
        0: {"code": "392010007", "display": "No diabetic retinopathy (disorder)"},
        1: {
            "code": "312991009",
            "display": "Mild nonproliferative diabetic retinopathy (disorder)",
        },
        2: {
            "code": "312993007",
            "display": "Moderate nonproliferative diabetic retinopathy (disorder)",
        },
        3: {
            "code": "312994001",
            "display": "Severe nonproliferative diabetic retinopathy (disorder)",
        },
        4: {"code": "59276001", "display": "Proliferative diabetic retinopathy (disorder)"},
    }

    dr_coding = snomed_codes.get(grade_num)
    is_ungradable = grade_num is None
    # Biomarkers are only meaningful when segmentation actually ran. The demo
    # passes csme_risk="UNGRADABLE" when seg_res is None, while the API bridge
    # forwards None: either signal — or a missing DR prediction — means never
    # emit 0/LOW values that would certify negative findings for an ungradable
    # capture.
    bio_unassessed = (biomarkers.get("csme_risk") in (None, "UNGRADABLE")) or is_ungradable
    if is_ungradable:
        # Do NOT assert disease when ungradable. Use NullFlavor UNK and
        # dataAbsentReason so validators don't see a false disorder code.
        dr_coding = {
            "system": "http://terminology.hl7.org/CodeSystem/v3-NullFlavor",
            "code": "UNK",
            "display": "Unknown - ungradable image",
        }
    # Gradable entries carry no "system" key and fall back to SNOMED.
    dr_system = dr_coding["system"] if "system" in dr_coding else snomed_system

    def _absent_observation(obs_id: str, text: str) -> dict[str, Any]:
        return {
            "resourceType": "Observation",
            "id": obs_id,
            "status": "final",
            "code": {"text": text},
            "dataAbsentReason": {
                "coding": [
                    {
                        "system": "http://terminology.hl7.org/CodeSystem/v3-NullFlavor",
                        "code": "UNK",
                        "display": "Unknown - ungradable image",
                    }
                ]
            },
        }

    biomarker_observations = (
        [
            _absent_observation("obs-microaneurysms", "Candidate Microaneurysm Count"),
            _absent_observation("obs-vessel-density", "Retinal Vessel Density Index"),
            _absent_observation("obs-csme-risk", "Clinically Significant Macular Edema Risk Level"),
        ]
        if bio_unassessed
        else [
            {
                "resourceType": "Observation",
                "id": "obs-microaneurysms",
                "status": "final",
                "code": {"text": "Candidate Microaneurysm Count"},
                "valueInteger": _safe_int(biomarkers.get("microaneurysm_count"), 0),
            },
            {
                "resourceType": "Observation",
                "id": "obs-vessel-density",
                "status": "final",
                "code": {"text": "Retinal Vessel Density Index"},
                "valueQuantity": {
                    "value": _safe_float(biomarkers.get("vessel_density_pct"), 0.0),
                    "unit": "%",
                    "system": "http://unitsofmeasure.org",
                    "code": "%",
                },
            },
            {
                "resourceType": "Observation",
                "id": "obs-csme-risk",
                "status": "final",
                "code": {"text": "Clinically Significant Macular Edema Risk Level"},
                "valueString": str(biomarkers.get("csme_risk") or "LOW"),
            },
        ]
    )

    fhir_report = {
        "resourceType": "DiagnosticReport",
        "id": resource_id,
        "meta": {
            "profile": ["https://nrces.in/ndhm/fhir/r4/StructureDefinition/DiagnosticReportRecord"]
        },
        "status": "final",
        "category": [
            {
                "coding": [
                    {
                        "system": "http://terminology.hl7.org/CodeSystem/v2-0074",
                        "code": "OP",
                        "display": "Ophthalmology",
                    }
                ]
            }
        ],
        "code": {
            "coding": [
                {
                    "system": "http://loinc.org",
                    "code": "81219-8",
                    "display": "Diabetic retinopathy study panel",
                }
            ],
            "text": "AI-Assisted Retinal Screening for Diabetic Retinopathy",
        },
        "subject": {"reference": f"Patient/{sanitized_pid}", "display": f"Patient {sanitized_pid}"},
        "effectiveDateTime": timestamp,
        "issued": timestamp,
        "performer": [
            {"display": doctor_name},
            {"display": "Drishti Screening Engine"},
        ],
        "conclusion": (
            f"Diabetic Retinopathy Grade: {grade_label}. "
            f"Referable DR: {'Yes' if referable else 'No'}. "
            f"CSME Risk: {'not assessed (ungradable capture)' if bio_unassessed else biomarkers.get('csme_risk', 'LOW')}. "
            f"Management Order: {doctor_action}."
        ),
        "conclusionCode": (
            []
            if is_ungradable
            else [
                {
                    "coding": [
                        {
                            "system": dr_system,
                            "code": dr_coding["code"],
                            "display": dr_coding["display"],
                        }
                    ]
                }
            ]
        ),
        "contained": [
            {
                "resourceType": "Observation",
                "id": "obs-dr-grade",
                "status": "final",
                "code": {
                    "coding": [
                        {
                            "system": "http://loinc.org",
                            "code": "68820-0",
                            "display": "Diabetic retinopathy severity grade",
                        }
                    ]
                },
                "valueCodeableConcept": {
                    "coding": [
                        {
                            "system": dr_system,
                            "code": dr_coding["code"],
                            "display": dr_coding["display"],
                        }
                    ],
                    "text": grade_label,
                },
            },
            {
                "resourceType": "Observation",
                "id": "obs-ai-confidence",
                "status": "final",
                "code": {"text": "Model Confidence / Reliability Metric"},
                **(
                    {
                        "valueQuantity": {
                            "value": round(confidence * 100, 1),
                            "unit": "%",
                            "system": "http://unitsofmeasure.org",
                            "code": "%",
                        }
                    }
                    if not is_ungradable
                    else {
                        "dataAbsentReason": {
                            "coding": [
                                {
                                    "system": "http://terminology.hl7.org/CodeSystem/v3-NullFlavor",
                                    "code": "UNK",
                                    "display": "Unknown - ungradable image",
                                }
                            ]
                        }
                    }
                ),
            },
            *biomarker_observations,
        ],
    }
    return fhir_report
