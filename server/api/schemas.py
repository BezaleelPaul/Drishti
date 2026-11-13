"""
Pydantic Schemas for Netra-AI FastAPI REST API.
Complies with clinical guidelines, plain-language patient summaries,
and ABDM tele-ophthalmology requirements.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from src.services import disagreement as disagreement_enums
from src.services import evidence as evidence_enums
from src.services import grading_policy as policy_enums


# -----------------------------------------------------------------------------
# 1. Patient Schemas
# -----------------------------------------------------------------------------
class PatientBase(BaseModel):
    name: str = Field(..., max_length=120, json_schema_extra={"example": "Ramesh Kumar"})
    age: int = Field(..., ge=1, le=120, json_schema_extra={"example": 54})
    gender: str = Field(..., max_length=32, json_schema_extra={"example": "Male"})
    phone: str | None = Field(None, max_length=32, json_schema_extra={"example": "+91 98451 22340"})
    abha_id: str | None = Field(
        None, max_length=32, json_schema_extra={"example": "91-4521-8890-3321"}
    )
    village: str | None = Field(
        None, max_length=120, json_schema_extra={"example": "Shivaji Nagar, PHC Bhor"}
    )
    screening_centre: str | None = Field(
        None, max_length=120, json_schema_extra={"example": "Bhor Rural Health Sub-Centre"}
    )

    # Diabetes Context
    known_diabetes: str = Field(
        "Unknown", max_length=32, json_schema_extra={"example": "Yes"}
    )  # 'Yes', 'No', 'Unknown'
    diabetes_duration_years: float | None = Field(
        None, ge=0, le=80, json_schema_extra={"example": 6.0}
    )
    hba1c: float | None = Field(None, ge=3, le=20, json_schema_extra={"example": 8.2})
    fasting_glucose: float | None = Field(
        None, ge=20, le=1000, json_schema_extra={"example": 165.0}
    )
    blood_pressure: str | None = Field(None, max_length=16, json_schema_extra={"example": "138/86"})

    # Upstream Risk Factors
    bmi: float | None = Field(None, ge=10, le=70, json_schema_extra={"example": 28.4})
    family_history: bool = Field(False, json_schema_extra={"example": True})
    physical_activity: str = Field(
        "Moderate", max_length=32, json_schema_extra={"example": "Sedentary"}
    )
    symptoms: list[str] = Field(
        default_factory=list,
        max_length=30,
        json_schema_extra={"example": ["Blurry vision", "Mild fatigue"]},
    )


class PatientCreate(PatientBase):
    patient_id: str | None = Field(None, json_schema_extra={"example": "PT-2026-101"})


class PatientResponse(PatientBase):
    patient_id: str
    created_at: str

    model_config = ConfigDict(from_attributes=True)


class PatientListResponse(BaseModel):
    total: int
    patients: list[PatientResponse]


# -----------------------------------------------------------------------------
# 2. Diabetes Risk Screening Schemas
# -----------------------------------------------------------------------------
class DiabetesRiskRequest(BaseModel):
    patient_id: str | None = None
    age: int = Field(..., ge=1, le=120, json_schema_extra={"example": 54})
    gender: str = Field(..., json_schema_extra={"example": "Male"})
    bmi: float = Field(..., ge=10, le=70, json_schema_extra={"example": 28.4})
    family_history: bool = Field(..., json_schema_extra={"example": True})
    physical_activity: str = Field("Sedentary", json_schema_extra={"example": "Sedentary"})
    symptoms: list[str] = Field(
        default_factory=list, max_length=30, json_schema_extra={"example": ["Blurry vision"]}
    )
    hba1c: float | None = Field(None, ge=3, le=20, json_schema_extra={"example": 8.2})
    fasting_glucose: float | None = Field(
        None, ge=20, le=1000, json_schema_extra={"example": 165.0}
    )
    random_glucose: float | None = Field(None, ge=20, le=1000, json_schema_extra={"example": 220.0})
    known_diabetes_years: float | None = Field(
        None, ge=0, le=80, json_schema_extra={"example": 6.0}
    )


class DiabetesRiskResponse(BaseModel):
    risk_score: float = Field(..., json_schema_extra={"example": 84.0})  # 0 to 100
    risk_level: str = Field(..., json_schema_extra={"example": "HIGH"})  # 'LOW', 'MODERATE', 'HIGH'
    pathway: str = Field(..., json_schema_extra={"example": "RETINAL_SCREENING_INDICATED"})
    # 'clinical_rule' for diagnostic biomarkers, 'ml' for model-weighted
    # prediction, and 'heuristic' when the fallback is used.
    # Clients MUST treat 'heuristic' as non-diagnostic and warn the user.
    risk_source: str = Field(..., json_schema_extra={"example": "ml"})
    clinical_rationale: list[str] = Field(default_factory=list)
    action_recommendation: str = Field(
        ...,
        json_schema_extra={
            "example": "Retinal imaging indicated for Diabetic Retinopathy screening."
        },
    )
    patient_friendly_guidance: str = Field(
        ...,
        json_schema_extra={
            "example": "The assessment indicates elevated risk factors. Clinical testing and retinal screening are recommended."
        },
    )


# -----------------------------------------------------------------------------
# 3. Retinal Quality & Screening Schemas
# -----------------------------------------------------------------------------
class RetinalQualityResponse(BaseModel):
    quality_grade: str = Field(
        ..., json_schema_extra={"example": "GOOD"}
    )  # 'GOOD', 'BORDERLINE', 'BAD'
    quality_score: float = Field(..., json_schema_extra={"example": 0.88})  # [0.0 - 1.0]
    is_reliable: bool = Field(..., json_schema_extra={"example": True})
    rejection_reasons: list[str] = Field(default_factory=list)
    suspected_clinical_cause: str | None = None
    # Machine-readable failure mode so clients never parse free text:
    # IMG_INVALID | IMG_NOT_FUNDUS | IMG_UNGRADABLE | None (gradable).
    error_code: str | None = Field(None, json_schema_extra={"example": "IMG_NOT_FUNDUS"})
    operator_action: str
    recapture_tips: list[str] = Field(default_factory=list)
    audio_guidance_hindi: str = Field(
        ..., json_schema_extra={"example": "कैमरा 2 सेमी पास लाएं और मरीज को हरी बत्ती पर देखने को कहें।"}
    )
    metrics: dict[str, Any] = Field(default_factory=dict)


class RetinalAnalysisResponse(BaseModel):
    screening_id: str = Field(..., json_schema_extra={"example": "SCR-90123-01"})
    patient_id: str = Field(..., json_schema_extra={"example": "PT-2026-101"})
    eye_side: str = Field(..., json_schema_extra={"example": "Right"})  # 'Right' or 'Left'
    camera_profile: str = Field(..., json_schema_extra={"example": "Generic Fundus Camera"})

    # Quality Gate Outcome
    quality_grade: str = Field(..., json_schema_extra={"example": "GOOD"})
    quality_score: float = Field(..., json_schema_extra={"example": 0.88})
    quality_passed: bool = Field(..., json_schema_extra={"example": True})
    rejection_reasons: list[str] = Field(default_factory=list)
    suspected_clinical_cause: str | None = None
    # Machine-readable terminal state: IMG_INVALID | IMG_NOT_FUNDUS |
    # IMG_UNGRADABLE | AI_LOW_CONFIDENCE | AI_UNAVAILABLE | AI_TIMEOUT | None.
    error_code: str | None = Field(None, json_schema_extra={"example": "IMG_NOT_FUNDUS"})

    # Model 2 DR Prediction (Suppressed if quality failed)
    dr_grade: int | None = Field(None, json_schema_extra={"example": 2})  # 0 to 4
    dr_label: str | None = Field(None, json_schema_extra={"example": "Moderate NPDR"})
    prediction_score: float | None = Field(
        None, json_schema_extra={"example": 0.742}
    )  # Model top-1 score
    probabilities: list[float] | None = None
    is_referable: bool | None = Field(None, json_schema_extra={"example": True})
    # Which classifier produced this grade: 'keras' | 'pytorch' | 'simulated' |
    # None (unknown, e.g. history rows written before this field existed).
    # Clients MUST treat 'simulated' as non-diagnostic.
    model_backend: str | None = Field(None, json_schema_extra={"example": "keras"})
    # Wall-clock duration of the screening pipeline (ms).
    inference_time_ms: float | None = Field(None, json_schema_extra={"example": 1250.0})

    # Segmentation biomarkers (None when ungradable — never estimated)
    vessel_density_pct: float | None = Field(None, json_schema_extra={"example": 14.2})
    microaneurysm_count: int | None = Field(None, json_schema_extra={"example": 12})
    csme_risk: str | None = Field(None, json_schema_extra={"example": "LOW"})
    min_fovea_distance_px: float | None = Field(None, json_schema_extra={"example": 310.0})

    # Uncertainty & Human Review Routing
    requires_human_review: bool = Field(..., json_schema_extra={"example": True})
    human_review_type: str = Field(
        ..., json_schema_extra={"example": "CLINICAL_LEVEL"}
    )  # 'NONE', 'OPERATOR_LEVEL', 'CLINICAL_LEVEL'
    human_review_reason: str | None = Field(
        None, json_schema_extra={"example": "Referable DR Grade 2 detected"}
    )
    confidence_flags: list[str] = Field(default_factory=list)

    # Explainability
    original_image_url: str | None = None
    gradcam_overlay_url: str | None = None
    gradcam_target_layer: str | None = Field(
        None, json_schema_extra={"example": "final_convolutional_block"}
    )
    gradcam_disclaimer: str = (
        "Grad-CAM visualizes regions of highest gradient activation influencing the "
        "model prediction. It does not constitute automated lesion segmentation."
    )

    # Clinical Actions & Plain Patient Language
    action_recommendation: str = Field(
        ...,
        json_schema_extra={
            "example": "Refer for comprehensive ophthalmic examination within 30 days."
        },
    )
    patient_plain_language_summary: str = Field(
        ...,
        json_schema_extra={
            "example": "Signs of mild-to-moderate changes in blood vessels detected. An eye doctor review has been scheduled."
        },
    )
    created_at: str
    # Field-capture time for offline-synced items (server created_at = sync time).
    captured_at: str | None = Field(None, json_schema_extra={"example": "2026-01-01T00:00:00"})


# -----------------------------------------------------------------------------
# 4. Doctor Review Queue & Decision Schemas
# -----------------------------------------------------------------------------
class DoctorReviewItem(BaseModel):
    review_id: str
    screening_id: str
    patient_id: str
    patient_name: str
    patient_age: int
    patient_gender: str
    village: str | None
    abha_id: str | None = None
    eye_side: str
    quality_grade: str
    dr_grade_num: int | None
    dr_grade_label: str | None
    dr_confidence: float | None
    # NULL in DB means ungradable (never coerced to False = healthy).
    is_referable: bool | None = None
    requires_human_review: bool
    human_review_type: str
    human_review_reason: str | None
    original_image_url: str | None
    gradcam_overlay_url: str | None
    status: str = (
        "PENDING"  # 'PENDING', 'CONFIRMED', 'OVERRIDDEN', 'REFERRED', 'RECAPTURE_REQUESTED'
    )
    doctor_name: str | None = None
    doctor_decision: str | None = None
    clinical_notes: str | None = None
    referral_urgency: str | None = None
    follow_up_days: int | None = None
    created_at: str
    reviewed_at: str | None = None


class DoctorReviewListResponse(BaseModel):
    total_pending: int
    items: list[DoctorReviewItem]


class DoctorDecisionRequest(BaseModel):
    doctor_name: str = Field(
        ..., max_length=120, json_schema_extra={"example": "Dr. S. Ramanathan, MD (Ophthal)"}
    )
    decision: str = Field(
        ..., json_schema_extra={"example": "CONFIRM_AND_REFER"}
    )  # 'CONFIRM', 'OVERRIDE_GRADE', 'REQUEST_RECAPTURE', 'ROUTINE_FOLLOW_UP'
    grade_override: int | None = Field(None, ge=0, le=4, json_schema_extra={"example": 2})
    clinical_notes: str = Field(
        ...,
        max_length=2000,
        json_schema_extra={
            "example": "Multiple microaneurysms confirmed in macular region. Refer to District Eye Hospital."
        },
    )
    referral_urgency: str = Field(
        "Within 30 Days", max_length=64, json_schema_extra={"example": "Within 30 Days"}
    )  # 'Immediate', 'Within 30 Days', 'Routine 12 Months'
    follow_up_days: int = Field(30, ge=0, le=365, json_schema_extra={"example": 30})


class DoctorDecisionResponse(BaseModel):
    success: bool
    message: str
    review_id: str
    updated_status: str


# -----------------------------------------------------------------------------
# 4b. Clinician Review Marker Schemas
# -----------------------------------------------------------------------------
class MarkerCircle(BaseModel):
    """A circular marker (optic disc or lesion candidate) in source-image pixel space."""

    x: int = Field(..., json_schema_extra={"example": 412})
    y: int = Field(..., json_schema_extra={"example": 862})
    r: int = Field(..., ge=0, json_schema_extra={"example": 168})


class MarkerPoint(BaseModel):
    """A point marker (fovea centre) in source-image pixel space."""

    x: int = Field(..., json_schema_extra={"example": 1385})
    y: int = Field(..., json_schema_extra={"example": 805})


# -----------------------------------------------------------------------------
# 4b. Evidence-linked grading extension (schema_version 1.0)
# -----------------------------------------------------------------------------
# Enums are re-exported from the criteria engine so Python and Dart parse the
# SAME value strings; pydantic serializes StrEnum members to their values.
LesionType = evidence_enums.LesionType
DetectionStatus = evidence_enums.DetectionStatus
CriterionStatus = policy_enums.CriterionStatus
DisagreementStatus = disagreement_enums.DisagreementStatus


class LesionEvidenceItem(BaseModel):
    """One classical-CV lesion candidate with criterion links.

    Coordinates are in SOURCE-image pixel space (see marker_service). Every
    item is a CANDIDATE, not a confirmed lesion — consumers must never
    present it as one.
    """

    lesion_id: str = Field(..., pattern=r"^LE-\d{4,}$", json_schema_extra={"example": "LE-0001"})
    lesion_type: LesionType
    detection_status: DetectionStatus
    x: int = Field(..., ge=0, json_schema_extra={"example": 412})
    y: int = Field(..., ge=0, json_schema_extra={"example": 862})
    radius: int = Field(..., ge=0, json_schema_extra={"example": 4})
    geometry_type: Literal["circle"] = "circle"
    detector_id: str = "classical_cv_segmenter"
    detector_version: str = "1.0"
    criterion_links: list[str] = Field(default_factory=list)
    evidence_notes: list[str] = Field(default_factory=list)
    image_width: int = Field(0, ge=0)
    image_height: int = Field(0, ge=0)


class CriterionEvaluationItem(BaseModel):
    """One versioned grading-criterion evaluation with evidence links."""

    criterion_id: str = Field(..., json_schema_extra={"example": "icdrss.ma_present"})
    status: CriterionStatus
    supporting_evidence_ids: list[str] = Field(default_factory=list)
    contradicting_evidence_ids: list[str] = Field(default_factory=list)
    reason_codes: list[str] = Field(default_factory=list)
    explanation_key: str = Field("", json_schema_extra={"example": "criterion_ma_present"})


class GradingPolicyInfo(BaseModel):
    """Which versioned policy produced the criteria evaluation."""

    policy_id: str
    policy_version: str
    framework: str


class DisagreementAssessment(BaseModel):
    """Deterministic CNN-vs-evidence reconciliation result.

    review_required=True escalates to the existing human-review path; it
    NEVER changes the CNN grade or silently selects either side.
    """

    status: DisagreementStatus
    reason_codes: list[str] = Field(default_factory=list)
    review_required: bool
    cnn_grade: int | None = Field(None, ge=0, le=4)
    evidence_implied_grade: int | None = Field(None, ge=0, le=4)
    explanation_key: str
    policy_id: str
    policy_version: str


# ---- Wire converters: engine dataclasses -> payload models -----------------
# The single serialization seam used by marker_service and ai_bridge so the
# two endpoints cannot drift apart.
def lesion_evidence_items(lesions) -> list[LesionEvidenceItem]:
    return [
        LesionEvidenceItem(
            lesion_id=l.lesion_id,
            lesion_type=l.lesion_type,
            detection_status=l.detection_status,
            x=l.x,
            y=l.y,
            radius=l.radius or 0,
            criterion_links=list(l.criterion_links),
            evidence_notes=list(l.evidence_notes),
            image_width=l.image_width,
            image_height=l.image_height,
        )
        for l in lesions
    ]


def criterion_evaluation_items(criteria) -> list[CriterionEvaluationItem]:
    return [
        CriterionEvaluationItem(
            criterion_id=c.criterion_id,
            status=c.status,
            supporting_evidence_ids=list(c.supporting_evidence_ids),
            contradicting_evidence_ids=list(c.contradicting_evidence_ids),
            reason_codes=list(c.reason_codes),
            explanation_key=c.explanation_key,
        )
        for c in criteria
    ]


def policy_info(result) -> GradingPolicyInfo:
    return GradingPolicyInfo(
        policy_id=result.policy_id,
        policy_version=result.policy_version,
        framework=result.framework,
    )


def disagreement_assessment(result) -> DisagreementAssessment:
    return DisagreementAssessment(
        status=result.status,
        reason_codes=list(result.reason_codes),
        review_required=result.review_required,
        cnn_grade=result.cnn_grade,
        evidence_implied_grade=result.evidence_implied_grade,
        explanation_key=result.explanation_key,
        policy_id=result.policy_id,
        policy_version=result.policy_version,
    )


class ReviewMarkersResponse(BaseModel):
    # Marker payload for GET /review/{review_id}/markers. Advisory only: a
    # marker failure never blocks the sign-off decision path.
    review_id: str = Field(..., json_schema_extra={"example": "REV-8F3A21C0B4D7"})
    # Honesty invariant: available=false (could not compute) is a DIFFERENT
    # state from available=true with an explicitly empty ma_candidates list
    # (healthy retina, no lesion candidates). Never conflate the two.
    available: bool = Field(..., json_schema_extra={"example": True})
    reason: str | None = Field(
        None,
        json_schema_extra={"example": "No microaneurysm candidates found"},
    )
    # Provenance: structurally pinned to classical CV segmentation — never
    # model attention, Grad-CAM, or a diagnosis. Literal rejects any other
    # value at construction time so the honesty invariant cannot be violated
    # by a dishonest payload (Req 2.2).
    source: Literal["classical_cv_segmentation"] = Field(
        "classical_cv_segmentation",
        json_schema_extra={"example": "classical_cv_segmentation"},
    )
    # Decoded source dimensions; 0 when unavailable (image never decoded).
    width: int = Field(0, ge=0, json_schema_extra={"example": 2240})
    height: int = Field(0, ge=0, json_schema_extra={"example": 1680})
    optic_disc: MarkerCircle | None = None
    fovea: MarkerPoint | None = None
    # Coordinates only — no vessel/exudate mask pixel data in this payload.
    # Always present; explicitly [] when there are no candidates (never null).
    ma_candidates: list[MarkerCircle] = Field(default_factory=list)

    # ---- Evidence-linked extension (schema_version 1.0) --------------------
    # All new fields are OPTIONAL with safe defaults so legacy consumers and
    # legacy payloads are unaffected. absence of these fields in an OLD
    # payload means the server predates the evidence contract — never that
    # evidence was negative.
    schema_version: Literal["1.0"] = Field("1.0")
    lesion_evidence: list[LesionEvidenceItem] = Field(default_factory=list)
    criteria_evaluation: list[CriterionEvaluationItem] = Field(default_factory=list)
    grading_policy: GradingPolicyInfo | None = None
    disagreement: DisagreementAssessment | None = None


# -----------------------------------------------------------------------------
# 5. Offline Synchronization Schemas
# -----------------------------------------------------------------------------
class OfflineSyncItem(BaseModel):
    local_screening_id: str
    patient_id: str
    eye_side: str
    # Pydantic-level byte cap: the route-level check runs only AFTER the
    # full JSON body is parsed, so without this, 20 max-size items would
    # sit in RAM (~210MB) before rejection. 15M chars ~= 11MB decoded.
    image_base64: str = Field(..., max_length=15_000_000)
    camera_profile: str | None = Field("Generic Fundus Camera", max_length=128)
    timestamp: str


class OfflineSyncBatchRequest(BaseModel):
    screening_centre: str = Field(..., max_length=120)
    operator_name: str = Field(..., max_length=120)
    # Capped at 5: each item costs a full multi-second inference in-request,
    # and the 90s client timeout cannot survive larger batches. The global
    # middleware body cap is sized for this bound (see ratelimit.SYNC cap).
    screenings: list[OfflineSyncItem] = Field(..., max_length=5)


class OfflineSyncBatchResponse(BaseModel):
    total_received: int
    total_synced: int
    failed_items: list[dict[str, str]]
    # LOCAL screening ids the client queued (its dedup key): the server ids
    # are traceable via synced_items. A previous version returned server ids
    # here, which clients match against local ids - the queue never drained.
    synced_screening_ids: list[str]
    synced_items: list[dict[str, str]] = Field(default_factory=list)


# -----------------------------------------------------------------------------
# 5b. De-identified Sync Schemas (/sync/v2, Ticket C-4)
# -----------------------------------------------------------------------------
# The v2 contract carries ONLY pseudonymized data (docs/PRIVACY.md). Two
# fail-closed mechanisms: `extra="forbid"` rejects unknown field names at
# parse time, and api/services/deid_linter.py re-checks the whitelist plus
# value-level regex tripwires (mobile/ABHA/salutation) before any write.
class DeidentifiedSyncItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    pseudo_screening_id: str = Field(..., min_length=4, max_length=64)
    pseudonym: str = Field(..., min_length=4, max_length=32)
    age_band: str | None = Field(None, max_length=8, pattern=r"^\d{1,2}-\d{1,2}$")
    gender: str | None = Field(None, max_length=16)
    eye_side: str = Field(..., pattern=r"^(Right|Left)$")
    dr_grade: int | None = Field(None, ge=0, le=4)
    dr_label: str | None = Field(None, max_length=32)
    probabilities: list[float] | None = Field(None, max_length=5)
    confidence: float | None = Field(None, ge=0.0, le=1.0)
    requires_human_review: bool = False
    # De-identified image: downscaled 512px JPEG (~<=1.1MB decoded). The
    # 15MB cap of v1 is deliberately NOT reused — v2 payloads are small.
    image_base64: str | None = Field(None, max_length=1_500_000)
    consent_version: str = Field(..., min_length=4, max_length=32)
    captured_at: str | None = Field(None, max_length=40)


class DeidentifiedSyncRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Tightened from v1's 5: no inference happens server-side in v2, but the
    # smaller cap keeps the request body inside the 2G-tolerant budget
    # (~650KB per batch at ~200KB/item with image).
    screenings: list[DeidentifiedSyncItem] = Field(..., max_length=3)


class DeidentifiedSyncResponse(BaseModel):
    total_received: int
    total_synced: int
    # Client dedup keys (pseudo_screening_id) that are durably stored;
    # retries of these ids replay from the stored row without re-writing.
    synced_pseudo_ids: list[str]
    failed_items: list[dict[str, str]] = Field(default_factory=list)


# -----------------------------------------------------------------------------
# 6. System Status Schemas
# -----------------------------------------------------------------------------
# 6. System Status Schemas
# -----------------------------------------------------------------------------
class SystemStatusResponse(BaseModel):
    ai_engine: str = "Ready (Model 1 Quality + Model 2 DR + Grad-CAM++)"
    camera_input: str = "Ready (Generic Fundus Camera / JPG / PNG)"
    network_connectivity: str = "Online"
    pending_doctor_reviews: int = 0
    total_patients_registered: int = 0
    total_screenings_completed: int = 0
    offline_queue_ready: bool = True
    models_loaded: dict[str, str]
    last_sync_time: str


# -----------------------------------------------------------------------------
# 7. PHC Dashboard Schemas
# -----------------------------------------------------------------------------
class RecentScreeningItem(BaseModel):
    screening_id: str
    patient_id: str
    patient_name: str | None = None
    created_at: str
    dr_grade_num: int | None = None
    dr_grade_label: str | None = None
    result_text: str
    is_referable: bool | None = None
    requires_human_review: bool = False
    status: str = Field(
        ...,
        description="One of: verified | referral | awaiting_specialist | rejected",
    )


class DashboardStats(BaseModel):
    today_screenings: int = 0
    awaiting_specialist: int = 0
    urgent_referrals: int = 0
    total_screenings: int = 0


class DashboardScreeningsResponse(BaseModel):
    items: list[RecentScreeningItem]
    stats: DashboardStats
