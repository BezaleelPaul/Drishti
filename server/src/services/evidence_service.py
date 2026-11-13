"""Shared evidence-payload builder — the single seam from detector output to
the evidence-linked wire contract (schema_version 1.0).

Used by the review marker service, the analyze-retina API bridge, and the
Streamlit referral screen (PDF section), so the three surfaces cannot drift
apart. Advisory by design: any failure degrades the caller to its legacy
shape / None fields — it never blocks grading and never fabricates a
negative result.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

_DETECTORS = ("classical_cv_segmenter", "classical_cv_segmenter:exudate")


def build_evidence_payload(
    img_rgb: Any,
    structures: Any,
    cnn_grade: int | None = None,
) -> dict[str, Any] | None:
    """Runs evidence normalization -> versioned criteria -> reconciliation.

    Returns a dict with keys ``lesion_evidence``, ``criteria_evaluation``,
    ``grading_policy``, ``disagreement``, ``schema_version`` — or None when
    the evidence chain cannot be built (caller must treat None as explicit
    absence, never as negative evidence).
    """
    try:
        from api.schemas import (
            criterion_evaluation_items,
            disagreement_assessment,
            lesion_evidence_items,
            policy_info,
        )
        from src.services.disagreement import reconcile
        from src.services.evidence import fovea_involved_ids, normalize_structures
        from src.services.grading_policy import evaluate_criteria

        landmarks, lesions, detector_status = normalize_structures(img_rgb, structures)
        fovea_ids, fovea_evaluable = fovea_involved_ids(lesions, landmarks, structures)
        ma_failed = not detector_status["classical_cv_segmenter"].ran
        exudate_failed = not detector_status["classical_cv_segmenter:exudate"].ran
        policy = evaluate_criteria(
            ma_evidence_ids=tuple(
                l.lesion_id for l in lesions if l.lesion_type.value == "microaneurysm_candidate"
            ),
            exudate_evidence_ids=tuple(
                l.lesion_id for l in lesions if l.lesion_type.value == "exudate_candidate"
            ),
            fovea_involved_ids=tuple(fovea_ids),
            ma_detector_failed=ma_failed,
            exudate_detector_failed=exudate_failed,
            fovea_evaluable=fovea_evaluable,
        )
        disagreement = reconcile(
            cnn_grade=cnn_grade,
            implied_grade=policy.implied.implied_grade,
            implied_status=policy.implied.implied_status.value,
            any_detector_failed=ma_failed or exudate_failed,
        )
        return {
            "schema_version": "1.0",
            "lesion_evidence": [
                item.model_dump(mode="json") for item in lesion_evidence_items(lesions)
            ],
            "criteria_evaluation": [
                item.model_dump(mode="json") for item in criterion_evaluation_items(policy.criteria)
            ],
            "grading_policy": policy_info(policy).model_dump(mode="json"),
            "disagreement": disagreement_assessment(disagreement).model_dump(mode="json"),
            # Raw assessment object for callers that need the typed form.
            "_disagreement_obj": disagreement,
            "_policy_obj": policy,
        }
    except Exception as exc:  # noqa: BLE001 - advisory extension must fail closed
        logger.warning("Evidence payload build failed: %s", exc)
        return None
