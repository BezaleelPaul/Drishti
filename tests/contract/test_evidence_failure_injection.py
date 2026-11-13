"""Failure-injection tests: the evidence extension must fail CLOSED.

A detector failure, malformed detector output, or invalid coordinates
degrades the payload to explicit absence (legacy markers / None fields) —
never a plausible-looking fabricated grade or negative evidence.
"""

import numpy as np

from api.schemas import ReviewMarkersResponse
from src.segmentation.structure_segmenter import RetinalStructureSegmenter
from src.services.evidence_service import build_evidence_payload


def _clean_fundus() -> np.ndarray:
    img = np.zeros((480, 640, 3), dtype=np.uint8)
    import cv2

    cv2.circle(img, (320, 240), 200, (60, 30, 35), -1)
    cv2.circle(img, (240, 240), 28, (240, 210, 170), -1)
    return img


def test_malformed_structures_yield_none_not_fabrication():
    img = _clean_fundus()
    result = RetinalStructureSegmenter().segment_structures(img)
    result.optic_disc_center = (999999, 999999)  # malformed detector output
    assert build_evidence_payload(img, result, cnn_grade=1) is None


def test_none_structures_yield_none():
    img = _clean_fundus()
    assert build_evidence_payload(img, None, cnn_grade=1) is None


def test_valid_run_returns_versioned_contract():
    img = _clean_fundus()
    result = RetinalStructureSegmenter().segment_structures(img)
    payload = build_evidence_payload(img, result, cnn_grade=0)
    assert payload is not None
    assert payload["schema_version"] == "1.0"
    assert isinstance(payload["lesion_evidence"], list)
    assert isinstance(payload["criteria_evaluation"], list)
    assert payload["grading_policy"]["policy_version"] == "1.0"
    # Stored CNN grade preserved verbatim in the reconciliation.
    assert payload["disagreement"]["cnn_grade"] == 0


def test_grade_mismatch_conflict_preserves_cnn_grade_and_escalates():
    # Craft the conflict at the disagreement layer directly (SYNTHETIC):
    # pixel-level conflict fixtures need detected MA dots, covered separately.
    from src.services.disagreement import DisagreementStatus, reconcile
    from src.services.grading_policy import ImpliedGradeStatus

    d = reconcile(
        cnn_grade=0,
        implied_grade=2,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.CONFLICT
    assert d.cnn_grade == 0  # never overwritten


def test_unavailable_cnn_grade_fails_closed_to_review():
    img = _clean_fundus()
    result = RetinalStructureSegmenter().segment_structures(img)
    payload = build_evidence_payload(img, result, cnn_grade=None)
    assert payload is not None
    d = payload["disagreement"]
    # A marker payload without a stored CNN grade cannot reconcile: the
    # designed fail-closed state is model_unavailable -> review required.
    # Absence is never read as negative evidence, and the grade stays None
    # (nothing fabricated).
    assert d["status"] == "model_unavailable"
    assert d["review_required"] is True
    assert d["cnn_grade"] is None


def test_payload_fits_pydantic_validation():
    img = _clean_fundus()
    result = RetinalStructureSegmenter().segment_structures(img)
    payload = build_evidence_payload(img, result, cnn_grade=2)
    assert payload is not None
    # Round-trip through the wire model: extension dicts must validate.
    ReviewMarkersResponse(
        review_id="REV-FI",
        available=True,
        lesion_evidence=payload["lesion_evidence"],
        criteria_evaluation=payload["criteria_evaluation"],
        grading_policy=payload["grading_policy"],
        disagreement=payload["disagreement"],
    )
