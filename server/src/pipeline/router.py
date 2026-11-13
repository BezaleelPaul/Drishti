from __future__ import annotations

import logging
import os
import uuid

import numpy as np
from PIL import Image

from src.classification.classifier import DRClassifier
from src.classification.gradcam import GradCAMExplainer
from src.pipeline.confidence import ConfidenceEvaluator
from src.pipeline.schema import (
    GradCAMResult,
    HumanReviewType,
    PipelineErrorCode,
    QualityGrade,
    ReassessmentOutcome,
    ScreeningRecord,
)
from src.quality.checker import ImageQualityChecker
from src.segmentation.structure_segmenter import RetinalStructureSegmenter

_logger = logging.getLogger("Drishti.PipelineRouter")


class ScreeningPipelineRouter:
    """
    Orchestrates the two-model AI-Assisted DR Screening Pipeline.
    Strictly locked to the approved flowchart (Section 3 and Section 5).
    Enforces the Non-Destructive Processing Rule (Section 20).
    """

    MAX_RECAPTURE_CAP = 2  # Hard cap of 2 recapture attempts per patient per session (Section 5/7)

    def __init__(
        self,
        quality_checker: ImageQualityChecker | None = None,
        dr_classifier: DRClassifier | None = None,
        gradcam_explainer: GradCAMExplainer | None = None,
        confidence_evaluator: ConfidenceEvaluator | None = None,
        structure_segmenter: RetinalStructureSegmenter | None = None,
        csme_engine: Any | None = None,
        bayesian_service: Any | None = None,
        strict_real_weights: bool = False,
        use_consensus: bool = False,
    ):
        """
        Args:
            strict_real_weights: Forwarded to the default DRClassifier —
                when True (and no dr_classifier per-instance override is
                supplied), constructing the router raises
                ClinicalModelUnavailableError instead of silently screening
                with the simulated backend.
            use_consensus: When True, defaults DRClassifier to the dual-engine
                consensus classifier (DRDetect ONNX + Meta DINOv3 ViT-Large).
        """
        self.quality_checker = quality_checker or ImageQualityChecker()
        if dr_classifier is not None:
            self.dr_classifier = dr_classifier
        elif use_consensus:
            self.dr_classifier = DRClassifier(
                use_consensus=True, strict_real_weights=strict_real_weights
            )
        else:
            self.dr_classifier = DRClassifier(strict_real_weights=strict_real_weights)

        self.gradcam_explainer = gradcam_explainer or GradCAMExplainer(
            classifier_backend=self.dr_classifier
        )
        self.confidence_evaluator = confidence_evaluator or ConfidenceEvaluator()
        self.structure_segmenter = structure_segmenter or RetinalStructureSegmenter()
        self.csme_engine = csme_engine
        self.bayesian_service = bayesian_service

    def process_image(
        self,
        image_input: str | np.ndarray | Image.Image,
        recapture_attempt_count: int = 0,
        output_dir: str | None = None,
        skip_gradcam: bool = False,
        quality_checker: ImageQualityChecker | None = None,
        clinical_profile: Any | None = None,
        enable_csme: bool = False,
    ) -> ScreeningRecord:
        """
        Executes Node 1 to Node 11 of the approved decision flow.

        Args:
            image_input: File path, numpy array, or PIL Image.
            recapture_attempt_count: Number of previous recapture attempts for this patient session.
            output_dir: Directory to save generated Grad-CAM overlays or reports.
            skip_gradcam: When True, Node 9 heatmap generation is deferred
                (gradcam_result.heatmap_generated is False). The caller is
                expected to generate it on demand via
                ``gradcam_explainer.generate_heatmap`` — e.g. only when the
                audit screen is actually viewed. A deliberate skip is NOT a
                failure and never forces human review by itself.
        """
        image_path = image_input if isinstance(image_input, str) else "in_memory_capture.jpg"

        # Clamp negative recapture counts to 0.
        try:
            recapture_attempt_count = int(recapture_attempt_count)
        except (TypeError, ValueError):
            recapture_attempt_count = 0
        recapture_attempt_count = max(recapture_attempt_count, 0)

        # -------------------------------------------------------------
        # Node 1: FUNDUS IMAGE (Raw retinal photograph enters the system)
        # Decode ONCE to canonical uint8 RGB and share the array with every
        # stage (checker, reassessment, classifier, Grad-CAM). Each stage used
        # to re-decode the same input (3-4x JPEG decode / normalize passes).
        # -------------------------------------------------------------
        np_img = self._load_rgb_for_reassessment(image_input)
        # Failure path: fall back to the original input so the checker emits
        # its canonical BAD/NON_FUNDUS result (identical behavior as before).
        stage_input = np_img if np_img is not None else image_input

        # -------------------------------------------------------------
        # Node 2: IMAGE QUALITY CHECK (Model 1 runs)
        # -------------------------------------------------------------
        active_quality_checker = quality_checker or self.quality_checker
        quality_res = active_quality_checker.assess_image(stage_input, strict_mode=False)

        # -------------------------------------------------------------
        # Node 3c: BAD IMAGE PATH
        # -------------------------------------------------------------
        if quality_res.grade == QualityGrade.BAD:
            reasons_list = [r.value for r in quality_res.reasons]

            # Check if retry limit reached (Section 5 / Section 18)
            if recapture_attempt_count >= self.MAX_RECAPTURE_CAP:
                # Force-escalate to human review
                return ScreeningRecord(
                    image_path=image_path,
                    quality_grade=QualityGrade.BAD,
                    quality_status="Unreliable (Retry limit reached)",
                    rejection_reasons=reasons_list,
                    recapture_attempt_count=recapture_attempt_count,
                    reassessment_outcome=ReassessmentOutcome.NOT_APPLICABLE,
                    suspected_clinical_cause=quality_res.suspected_clinical_cause,
                    dr_prediction=None,
                    confidence_assessment=None,
                    gradcam_result=None,
                    human_review_required=True,
                    human_review_type=HumanReviewType.OPERATOR_LEVEL,
                    human_review_reason=(
                        f"Recapture cap of {self.MAX_RECAPTURE_CAP} attempts reached. "
                        f"Operator/clinician must inspect patient eye directly."
                    ),
                    action=(
                        f"Recapture cap reached ({recapture_attempt_count}/{self.MAX_RECAPTURE_CAP}). "
                        "Escalate to supervising clinician for on-site physical evaluation."
                    ),
                    quality_metrics=quality_res.metrics,
                    error_code=quality_res.error_code or PipelineErrorCode.IMG_UNGRADABLE,
                )

            # Standard Bad: prompt for immediate recapture
            return ScreeningRecord(
                image_path=image_path,
                quality_grade=QualityGrade.BAD,
                quality_status="Unreliable",
                rejection_reasons=reasons_list,
                recapture_attempt_count=recapture_attempt_count + 1,
                reassessment_outcome=ReassessmentOutcome.NOT_APPLICABLE,
                suspected_clinical_cause=quality_res.suspected_clinical_cause,
                dr_prediction=None,
                confidence_assessment=None,
                gradcam_result=None,
                human_review_required=False,
                human_review_type=HumanReviewType.NONE,
                action=(
                    "Recapture image. Do not display a DR grade for an image "
                    "that fails the reliability gate."
                ),
                quality_metrics=quality_res.metrics,
                error_code=quality_res.error_code or PipelineErrorCode.IMG_UNGRADABLE,
            )

        # -------------------------------------------------------------
        # Node 3b: BORDERLINE IMAGE PATH -> Node 4: REASSESSMENT
        # -------------------------------------------------------------
        reassessment_outcome = ReassessmentOutcome.NOT_APPLICABLE
        reassessment_struct = None
        if quality_res.grade == QualityGrade.BORDERLINE:
            # Reassessment: Verify anatomical landmark visibility (Optic Disc, Fovea, Retinal Vasculature)
            # NOTE: reuses the Node-1 shared decode (no second file open).
            anatomical_visible = False
            if np_img is not None:
                try:
                    struct_res = self.structure_segmenter.segment_structures(np_img)
                    reassessment_struct = struct_res
                    # Verify key anatomical landmarks for diagnostic reliability.
                    # Floors scale with resolution AND retinal area (not full frame):
                    # a 64px thumbnail has a proportionally correct ~5px OD and
                    # ~30% FOV, so absolute cutoffs would block CLEAR forever.
                    _rh, _rw = np_img.shape[:2]
                    # OD floor scales with resolution (min 2px): a 32px capture
                    # has a proportionally correct ~2px OD that must stay reachable.
                    _min_od_r = max(2, int(0.02 * min(_rh, _rw)))
                    has_od = struct_res.optic_disc_radius >= _min_od_r and (
                        struct_res.optic_disc_center[0] > 0 and struct_res.optic_disc_center[1] > 0
                    )
                    has_fovea = struct_res.fovea_center[0] > 0 and struct_res.fovea_center[1] > 0
                    has_vessels = False
                    if struct_res.vessel_mask is not None:
                        from src.image_io import retinal_mask as _rm
                        from src.image_io import rgb_to_gray as _to_gray

                        # Shared luma conversion (NOT mean(axis=2)): the mask
                        # must use the same denominator as vessel_density_pct.
                        _gray = _to_gray(np_img)
                        _retinal_px = max(int(np.count_nonzero(_rm(_gray))), 1)
                        # 0.5% of RETINAL pixels (same denominator as
                        # vessel_density_pct), with a small absolute floor so
                        # sensor noise on thumbnails cannot pass. Floors stay
                        # proportional: a 32px capture keeps a reachable gate.
                        _min_vessel_px = max(5, int(0.005 * _retinal_px))
                        has_vessels = (
                            struct_res.vessel_density_raw >= 0.8
                            and np.count_nonzero(struct_res.vessel_mask) >= _min_vessel_px
                        )
                    if has_od and has_fovea and has_vessels:
                        anatomical_visible = True
                except Exception:  # noqa: BLE001 - continue with deterministic fallback
                    anatomical_visible = False

            # Node 5: STILL UNRELIABLE?
            if anatomical_visible:
                # 5-No: joins Good path holding original unmodified pixels
                reassessment_outcome = ReassessmentOutcome.CLEARED
            else:
                # 5-Yes: Reassessment failed -> Recapture / Human Review
                reassessment_outcome = ReassessmentOutcome.FAILED
                # Enforce hard recapture cap before incrementing.
                if recapture_attempt_count >= self.MAX_RECAPTURE_CAP:
                    reasons = [r.value for r in quality_res.reasons]
                    return ScreeningRecord(
                        image_path=image_path,
                        quality_grade=QualityGrade.BORDERLINE,
                        quality_status="Unreliable (Retry limit reached)",
                        rejection_reasons=reasons,
                        recapture_attempt_count=recapture_attempt_count,
                        reassessment_outcome=reassessment_outcome,
                        suspected_clinical_cause=quality_res.suspected_clinical_cause,
                        dr_prediction=None,
                        confidence_assessment=None,
                        gradcam_result=None,
                        human_review_required=True,
                        human_review_type=HumanReviewType.OPERATOR_LEVEL,
                        human_review_reason=(
                            f"Recapture cap of {self.MAX_RECAPTURE_CAP} attempts reached (retry limit reached). "
                            "Borderline image failed anatomical landmark reassessment; "
                            "operator/clinician must inspect patient eye directly."
                        ),
                        action=(
                            f"Recapture cap reached ({recapture_attempt_count}/{self.MAX_RECAPTURE_CAP}, retry limit reached). "
                            "Escalate to supervising clinician for on-site physical evaluation. "
                            "Image does NOT proceed to DR Classification."
                        ),
                        quality_metrics=quality_res.metrics,
                        error_code=quality_res.error_code or PipelineErrorCode.IMG_UNGRADABLE,
                    )
                reasons = [r.value for r in quality_res.reasons]
                return ScreeningRecord(
                    image_path=image_path,
                    quality_grade=QualityGrade.BORDERLINE,
                    quality_status="Unreliable (Failed Reassessment)",
                    rejection_reasons=reasons,
                    recapture_attempt_count=recapture_attempt_count + 1,
                    reassessment_outcome=reassessment_outcome,
                    suspected_clinical_cause=quality_res.suspected_clinical_cause,
                    dr_prediction=None,
                    confidence_assessment=None,
                    gradcam_result=None,
                    human_review_required=True,
                    human_review_type=HumanReviewType.OPERATOR_LEVEL,
                    human_review_reason="Borderline image failed anatomical landmark reassessment (landmarks obscured).",
                    action=(
                        f"Reassessment failed. Recapture attempt #{recapture_attempt_count + 1}/{self.MAX_RECAPTURE_CAP}. "
                        "Request fresh capture. Image does NOT proceed to DR Classification."
                    ),
                    quality_metrics=quality_res.metrics,
                    error_code=quality_res.error_code or PipelineErrorCode.IMG_UNGRADABLE,
                )

        # -------------------------------------------------------------
        # Node 6: RELIABLE ORIGINAL IMAGE
        # Convergence point for 3a (Good) and 5-No (Cleared Borderline).
        # Holds original, unmodified pixel data (Section 20).
        # -------------------------------------------------------------
        quality_status = (
            "Reliable"
            if reassessment_outcome != ReassessmentOutcome.CLEARED
            else "Reliable (Cleared by Reassessment)"
        )

        # -------------------------------------------------------------
        # Node 7: DR CLASSIFICATION (Model 2 runs)
        # -------------------------------------------------------------
        dr_result = self.dr_classifier.predict(stage_input)

        # -------------------------------------------------------------
        # Node 8: CONFIDENCE / UNCERTAINTY HANDLING
        # -------------------------------------------------------------
        confidence_result = self.confidence_evaluator.evaluate(dr_result)

        # -------------------------------------------------------------
        # Node 9: GRAD-CAM EXPLAINABILITY
        # Generated for all images reaching this node per Section 8, unless
        # the caller defers it (skip_gradcam) for on-demand generation on
        # the audit screen. A deliberate skip is not a failure.
        # -------------------------------------------------------------
        overlay_save_path = None
        if output_dir and not skip_gradcam:
            os.makedirs(output_dir, exist_ok=True)
            overlay_save_path = os.path.join(output_dir, f"gradcam_{uuid.uuid4().hex[:8]}.png")

        gradcam_failed = False
        gradcam_error = ""
        if skip_gradcam:
            gradcam_res = GradCAMResult(
                heatmap_generated=False,
                heatmap_array=None,
                overlay_path=None,
                target_layer="deferred (on-demand)",
            )
        else:
            try:
                gradcam_res = self.gradcam_explainer.generate_heatmap(
                    image_input=stage_input,
                    target_grade=dr_result.predicted_grade,
                    save_path=overlay_save_path,
                    classifier=self.dr_classifier,
                )
            except Exception as e:  # noqa: BLE001 - preserve screening record on fallback
                gradcam_failed = True
                gradcam_error = str(e)
                _logger.warning("Grad-CAM generation failed: %s", gradcam_error)
                gradcam_res = GradCAMResult(
                    heatmap_generated=False,
                    heatmap_array=None,
                    overlay_path=overlay_save_path,
                )

        # -------------------------------------------------------------
        # Node 9b: ADVANCED CLINICAL ENGINES (CSME & Bayesian Prior)
        # -------------------------------------------------------------
        csme_res = None
        if enable_csme and np_img is not None:
            if self.csme_engine is None:
                from src.services.csme_engine import CSMEGeometricEngine

                self.csme_engine = CSMEGeometricEngine(segmenter=self.structure_segmenter)
            try:
                csme_res = self.csme_engine.evaluate(
                    stage_input, landmarks=reassessment_struct
                )
            except Exception as e:
                _logger.warning("CSME evaluation failed: %s", e)

        coupled_res = None
        if clinical_profile is not None:
            if self.bayesian_service is None:
                from src.services.bayesian_risk_coupling import BayesianRiskCouplingService

                self.bayesian_service = BayesianRiskCouplingService()
            try:
                coupled_res = self.bayesian_service.couple(
                    dr_result, clinical_profile=clinical_profile
                )
            except Exception as e:
                _logger.warning("Bayesian risk coupling failed: %s", e)

        # -------------------------------------------------------------
        # Node 10 & 11: SCREENING RESULT & HUMAN REVIEW ROUTING
        # -------------------------------------------------------------
        # Any referable grade (2+) mandates clinician review even when the
        # classifier is confident: a confident model must never silently
        # finalize a referral-grade diagnosis without a human in the loop.
        referable_review = bool(
            dr_result.predicted_grade.is_referable
            or (csme_res and csme_res.urgent_referral)
            or (coupled_res and coupled_res.is_referable_coupled)
        )
        human_review_req = bool(
            confidence_result.requires_human_review or gradcam_failed or referable_review
        )
        review_type = HumanReviewType.CLINICAL_LEVEL if human_review_req else HumanReviewType.NONE
        flags = list(confidence_result.flags) if confidence_result.flags else []
        if csme_res and csme_res.urgent_referral:
            flags.append("Urgent Macular Edema (CSME) detected near fovea")
        if coupled_res and coupled_res.is_referable_coupled and not dr_result.predicted_grade.is_referable:
            flags.append(
                f"Bayesian coupling escalated patient to referable tier due to systemic risk ({coupled_res.systemic_risk_level.value})"
            )
        if dr_result.predicted_grade.is_referable and not confidence_result.requires_human_review:
            flags.append(
                f"Referable {dr_result.predicted_grade.label} requires clinician confirmation per triage protocol"
            )
        if gradcam_failed:
            flags.append(
                f"Grad-CAM explainability failed ({gradcam_error or 'unknown error'}): mandatory human review"
            )
        review_reason = " | ".join(flags) if human_review_req else None

        # -------------------------------------------------------------
        # Section 7 uncertainty gate. When the model itself is not
        # confident (or the top-2 classes are ambiguous) the prediction is
        # PROVISIONAL: it is retained for clinician over-read but must never
        # be released as an automated result. Clients branch on
        # AI_LOW_CONFIDENCE instead of parsing prose. A referable grade keeps
        # its referral action - under-referring is the larger clinical risk.
        # -------------------------------------------------------------
        uncertain = (not confidence_result.is_confident) or bool(confidence_result.is_ambiguous)
        error_code = PipelineErrorCode.AI_LOW_CONFIDENCE if uncertain else None

        if csme_res and csme_res.urgent_referral:
            action_text = "URGENT OPHTHALMOLOGY REFERRAL: High-risk CSME detected near fovea. Specialist evaluation required."
        elif coupled_res and coupled_res.is_referable_coupled and not dr_result.predicted_grade.is_referable:
            action_text = f"{coupled_res.clinical_narrative} Rescreen in {coupled_res.recommended_screening_interval_months} months."
        elif uncertain and not referable_review:
            action_text = (
                "AI confidence below the reliability threshold: no automated "
                "result released. Image routed for mandatory clinician review."
            )
        elif dr_result.predicted_grade.value == 0:
            if human_review_req:
                action_text = "Routine annual screening recommended. Low confidence / ambiguity flagged for clinical verification."
            else:
                action_text = "Routine screening: No DR detected. Rescreen in 12 months."
        elif dr_result.predicted_grade.value == 1:
            if human_review_req:
                action_text = (
                    "Mild NPDR flagged for clinician over-read. Follow-up per clinical guidelines."
                )
            else:
                action_text = "Mild NPDR detected. Routine 6-12 month follow-up recommended."
        else:
            action_text = "Refer for ophthalmic evaluation / human review per workflow."

        return ScreeningRecord(
            image_path=image_path,
            quality_grade=quality_res.grade,
            quality_status=quality_status,
            rejection_reasons=[],
            recapture_attempt_count=recapture_attempt_count,
            reassessment_outcome=reassessment_outcome,
            suspected_clinical_cause=None,
            dr_prediction=dr_result,
            confidence_assessment=confidence_result,
            gradcam_result=gradcam_res,
            human_review_required=human_review_req,
            human_review_type=review_type,
            human_review_reason=review_reason,
            action=action_text,
            quality_metrics=quality_res.metrics,
            reassessment_structures=reassessment_struct,
            model_backend=self.dr_classifier.get_backend(),
            error_code=error_code,
            csme_result=csme_res,
            coupled_assessment=coupled_res,
        )

    @staticmethod
    def _load_rgb_for_reassessment(
        image_input: str | np.ndarray | Image.Image,
    ) -> np.ndarray | None:
        """Minimal public image loader (PIL/numpy) for reassessment; avoids private checker API."""
        # Prefer a public loader if the checker ever exposes one (backward compat).
        try:
            from src.image_io import to_rgb_uint8

            if isinstance(image_input, str):
                if not os.path.exists(image_input):
                    return None
                # Shared funnel: same cap/normalization as the array path.
                return to_rgb_uint8(np.array(Image.open(image_input).convert("RGB")))
            if isinstance(image_input, Image.Image):
                return to_rgb_uint8(np.array(image_input.convert("RGB")))
            if isinstance(image_input, np.ndarray):
                # Single shared loader (float scale, NaN fail-closed, RGBA
                # strip, int clip). See src/image_io.
                return to_rgb_uint8(image_input)
            return None
        except Exception:  # noqa: BLE001 - failure routes to human review
            return None
