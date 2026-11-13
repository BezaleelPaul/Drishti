"""Bilateral and Multi-Field Patient Screening Session Aggregator.

Synthesizes Right Eye (OD) and Left Eye (OS) fundus captures, plus secondary
fields (Macula Field 1, Disc Field 2), into an integrated patient-level diagnostic record.

Key Clinical Rules:
1. Patient-Level Triage (Worst-Eye Rule): Clinical urgency and referral are dictated
   by the most severely affected eye (max-pooling across gradable eyes).
2. Inter-Ocular Asymmetry Alert: Clinically significant discordance between eyes
   (e.g., Grade 0 in OD vs Grade 3 in OS, or Delta >= 2 grades) flags potential
   carotid artery stenosis, asymmetric ocular ischemia, or prior focal treatment,
   mandating specialist over-read.
3. Incomplete Bilateral Data Handling: If one eye fails quality gates after the recapture cap,
   the session escalates to operator review while preserving the gradable eye's finding.
4. Multimodal Systemic Coupling: Ingests PatientClinicalProfile to modulate patient-level
   referral thresholds via Bayesian prior coupling.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
import logging
import uuid
from typing import Any

import numpy as np
from PIL import Image

from src.clinical_risk.schema import PatientClinicalProfile
from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import (
    DRGrade,
    HumanReviewType,
    PipelineErrorCode,
    QualityGrade,
    ScreeningRecord,
)
from src.services.bayesian_risk_coupling import (
    BayesianRiskCouplingService,
    CombinedCarePath,
    CoupledAssessmentResult,
)
from src.services.csme_engine import CSMERiskLevel, CSMERiskResult, CSMEGeometricEngine

logger = logging.getLogger(__name__)


class EyeLaterality(str, Enum):
    OD = "OD"  # Oculus Dexter (Right Eye)
    OS = "OS"  # Oculus Sinister (Left Eye)
    OU = "OU"  # Oculus Uterque (Both Eyes)
    UNKNOWN = "UNKNOWN"


class RetinalField(str, Enum):
    FIELD_1_MACULA = "FIELD_1_MACULA"  # Macula-centered (ETDRS Field 2)
    FIELD_2_DISC = "FIELD_2_DISC"      # Disc-centered (ETDRS Field 1)
    WIDEFIELD = "WIDEFIELD"
    UNKNOWN = "UNKNOWN"


@dataclass
class EyeCapture:
    image: str | np.ndarray | Image.Image
    laterality: EyeLaterality
    field_type: RetinalField = RetinalField.UNKNOWN
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class PatientSessionResult:
    """Consolidated bilateral screening dossier for an individual patient."""

    patient_id: str
    session_id: str
    timestamp: str
    od_record: ScreeningRecord | None = None
    os_record: ScreeningRecord | None = None
    additional_records: list[ScreeningRecord] = field(default_factory=list)

    # Patient-level triage
    patient_dr_grade: DRGrade = DRGrade.NO_DR
    patient_triage_tier: int = 0  # 0: Clean, 1: Mild, 2: Referable
    is_referable: bool = False
    interocular_asymmetry_detected: bool = False
    asymmetry_narrative: str | None = None
    csme_detected_any_eye: bool = False

    # Systemic risk coupling
    coupled_risk: CoupledAssessmentResult | None = None

    # Triage flags
    human_review_required: bool = False
    human_review_type: HumanReviewType = HumanReviewType.NONE
    human_review_reasons: list[str] = field(default_factory=list)
    overall_action_plan: str = ""

    def format_session_summary(self) -> str:
        """Generates a text summary of the bilateral patient session."""
        lines = [
            f"=== PATIENT SCREENING SESSION DOSSIER ===",
            f"Patient ID:        {self.patient_id}",
            f"Session ID:        {self.session_id}",
            f"Timestamp:         {self.timestamp}",
            f"Patient DR Grade:  Grade {self.patient_dr_grade.value} — {self.patient_dr_grade.label}",
            f"Referable Status:  {'YES (REFERRAL REQUIRED)' if self.is_referable else 'NO (NON-REFERABLE)'}",
            f"CSME Detected:     {'YES (URGENT MACULAR EDEMA)' if self.csme_detected_any_eye else 'NO'}",
        ]
        if self.interocular_asymmetry_detected:
            lines.append(f"Asymmetry Alert:   {self.asymmetry_narrative}")

        lines.append(f"--- Eye Captures ---")
        if self.od_record:
            od_grade = (
                f"Grade {self.od_record.dr_prediction.predicted_grade.value}"
                if self.od_record.dr_prediction
                else "Ungradable"
            )
            lines.append(f"Right Eye (OD):    {self.od_record.quality_status} | DR: {od_grade}")
        else:
            lines.append("Right Eye (OD):    Not provided")

        if self.os_record:
            os_grade = (
                f"Grade {self.os_record.dr_prediction.predicted_grade.value}"
                if self.os_record.dr_prediction
                else "Ungradable"
            )
            lines.append(f"Left Eye (OS):     {self.os_record.quality_status} | DR: {os_grade}")
        else:
            lines.append("Left Eye (OS):     Not provided")

        if self.coupled_risk:
            lines.append(f"Systemic Prior:    {self.coupled_risk.systemic_risk_level.value} -> Path: {self.coupled_risk.recommended_pathway.value}")

        lines.append(f"Action Plan:       {self.overall_action_plan}")
        if self.human_review_required:
            lines.append(f"Human Review:      FLAGGED ({self.human_review_type.value}) - {' | '.join(self.human_review_reasons)}")
        return "\n".join(lines)


class PatientScreeningSession:
    """Aggregates and triages multi-image and bilateral screening sessions."""

    def __init__(
        self,
        router: ScreeningPipelineRouter | None = None,
        bayesian_service: BayesianRiskCouplingService | None = None,
        csme_engine: CSMEGeometricEngine | None = None,
    ):
        self.router = router or ScreeningPipelineRouter()
        self.bayesian_service = bayesian_service or BayesianRiskCouplingService()
        self.csme_engine = csme_engine or CSMEGeometricEngine()

    def process_bilateral_session(
        self,
        patient_id: str,
        od_image: str | np.ndarray | Image.Image | None = None,
        os_image: str | np.ndarray | Image.Image | None = None,
        additional_captures: list[EyeCapture] | None = None,
        clinical_profile: PatientClinicalProfile | None = None,
        recapture_counts: dict[str, int] | None = None,
        output_dir: str | None = None,
        skip_gradcam: bool = False,
    ) -> PatientSessionResult:
        """Executes full pipeline routing for OD and OS captures and computes patient-level triage."""
        session_id = f"SES-{uuid.uuid4().hex[:8].upper()}"
        ts = datetime.now(timezone.utc).isoformat()
        rc_map = recapture_counts or {}

        od_record = None
        os_record = None
        additional_records = []
        review_reasons = []

        # Gather pairs of (record, original_image)
        input_pairs: list[tuple[ScreeningRecord, Any]] = []

        # 1. Process Right Eye (OD)
        if od_image is not None:
            od_rc = rc_map.get("OD", 0)
            od_record = self.router.process_image(
                image_input=od_image,
                recapture_attempt_count=od_rc,
                output_dir=output_dir,
                skip_gradcam=skip_gradcam,
            )
            input_pairs.append((od_record, od_image))
            if od_record.human_review_required:
                review_reasons.append(f"OD: {od_record.human_review_reason or 'Review required'}")

        # 2. Process Left Eye (OS)
        if os_image is not None:
            os_rc = rc_map.get("OS", 0)
            os_record = self.router.process_image(
                image_input=os_image,
                recapture_attempt_count=os_rc,
                output_dir=output_dir,
                skip_gradcam=skip_gradcam,
            )
            input_pairs.append((os_record, os_image))
            if os_record.human_review_required:
                review_reasons.append(f"OS: {os_record.human_review_reason or 'Review required'}")

        # 3. Process any additional auxiliary fields (e.g. Field 1 / Field 2)
        if additional_captures:
            for i, cap in enumerate(additional_captures):
                cap_rc = rc_map.get(f"aux_{i}", 0)
                rec = self.router.process_image(
                    image_input=cap.image,
                    recapture_attempt_count=cap_rc,
                    output_dir=output_dir,
                    skip_gradcam=skip_gradcam,
                )
                additional_records.append(rec)
                input_pairs.append((rec, cap.image))
                if rec.human_review_required:
                    review_reasons.append(f"Aux {cap.laterality.value}: {rec.human_review_reason or 'Review required'}")

        # Gather all valid gradable records
        all_records = [r for r in [od_record, os_record, *additional_records] if r is not None]
        gradable_records = [r for r in all_records if r.dr_prediction is not None]

        # 4. Check CSME across all images
        csme_detected = False
        for rec, raw_img in input_pairs:
            if rec.dr_prediction is not None:
                csme_res = self.csme_engine.evaluate(raw_img, landmarks=rec.reassessment_structures)
                rec.csme_result = csme_res
                if csme_res.urgent_referral:
                    csme_detected = True
                    review_reasons.append("Urgent Macular Edema (CSME) detected in retinal scan")

        # 5. Patient-Level Triage (Worst-Eye Rule)
        if gradable_records:
            worst_rec = max(gradable_records, key=lambda r: r.dr_prediction.predicted_grade.value)
            patient_grade = worst_rec.dr_prediction.predicted_grade
            patient_dr_pred = worst_rec.dr_prediction
        else:
            patient_grade = DRGrade.NO_DR
            patient_dr_pred = None

        # Determine triage tier: 0 (Grade 0), 1 (Grade 1), 2 (Grade 2+)
        if patient_grade.value == 0:
            triage_tier = 0
        elif patient_grade.value == 1:
            triage_tier = 1
        else:
            triage_tier = 2

        is_referable = bool(triage_tier == 2 or csme_detected)

        # 6. Inter-Ocular Asymmetry Evaluation
        asymmetry_detected = False
        asymmetry_narrative = None
        if od_record and os_record and od_record.dr_prediction and os_record.dr_prediction:
            od_val = od_record.dr_prediction.predicted_grade.value
            os_val = os_record.dr_prediction.predicted_grade.value
            diff = abs(od_val - os_val)
            if diff >= 2:
                asymmetry_detected = True
                asymmetry_narrative = (
                    f"Significant inter-ocular asymmetry detected: OD Grade {od_val} vs OS Grade {os_val} "
                    f"(Delta = {diff}). Rule out asymmetric ocular ischemia, carotid stenosis, or prior unilateral treatment."
                )
                review_reasons.append(asymmetry_narrative)
            elif (od_val >= 2 and os_val == 0) or (os_val >= 2 and od_val == 0):
                asymmetry_detected = True
                asymmetry_narrative = (
                    f"Discordant bilateral findings: One eye is Referable (Grade {max(od_val, os_val)}) "
                    f"while the fellow eye is Clean (Grade 0). Clinician over-read required."
                )
                review_reasons.append(asymmetry_narrative)

        # 7. Bayesian Prior Coupling (if clinical profile provided)
        coupled_res = None
        if clinical_profile is not None and patient_dr_pred is not None:
            coupled_res = self.bayesian_service.couple(
                retinal_result=patient_dr_pred,
                clinical_profile=clinical_profile,
            )
            if coupled_res.is_referable_coupled and not is_referable:
                is_referable = True
                review_reasons.append(
                    f"Bayesian coupling escalated patient to referable tier due to systemic metabolic burden ({coupled_res.systemic_risk_level.value})"
                )

        # 8. Determine Human Review Escalation
        any_ungradable = any(
            r.quality_grade in (QualityGrade.BAD, QualityGrade.BORDERLINE)
            and r.dr_prediction is None
            for r in all_records
        )

        requires_review = bool(
            is_referable
            or csme_detected
            or asymmetry_detected
            or any_ungradable
            or len(review_reasons) > 0
        )

        review_type = HumanReviewType.NONE
        if requires_review:
            if is_referable or csme_detected or asymmetry_detected:
                review_type = HumanReviewType.CLINICAL_LEVEL
            else:
                review_type = HumanReviewType.OPERATOR_LEVEL

        # 9. Overall Action Plan
        if csme_detected:
            action_plan = "URGENT OPHTHALMOLOGY REFERRAL: High-risk CSME detected near fovea. Specialist evaluation required within 2 weeks."
        elif is_referable:
            action_plan = f"Referable Diabetic Retinopathy (Grade {patient_grade.value}): Mandatory ophthalmic tele-review / hospital referral."
        elif any_ungradable and not gradable_records:
            action_plan = "All retinal captures ungradable. Operator physical inspection or pupil dilation required."
        elif any_ungradable and gradable_records:
            action_plan = f"Partial screening complete (Fellow eye ungradable). Clinical follow-up based on gradable eye (Grade {patient_grade.value})."
        elif coupled_res:
            action_plan = f"{coupled_res.clinical_narrative} Rescreen in {coupled_res.recommended_screening_interval_months} months."
        elif patient_grade.value == 1:
            action_plan = "Mild NPDR detected in worst eye. Rescreen in 6-12 months with routine glycemic control."
        else:
            action_plan = "No DR detected bilaterally. Routine annual diabetic eye screening recommended."

        return PatientSessionResult(
            patient_id=patient_id,
            session_id=session_id,
            timestamp=ts,
            od_record=od_record,
            os_record=os_record,
            additional_records=additional_records,
            patient_dr_grade=patient_grade,
            patient_triage_tier=triage_tier,
            is_referable=is_referable,
            interocular_asymmetry_detected=asymmetry_detected,
            asymmetry_narrative=asymmetry_narrative,
            csme_detected_any_eye=csme_detected,
            coupled_risk=coupled_res,
            human_review_required=requires_review,
            human_review_type=review_type,
            human_review_reasons=review_reasons,
            overall_action_plan=action_plan,
        )
