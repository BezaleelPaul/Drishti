"""Wire-format contract test: Python payload -> Dart-parseable JSON.

The Flutter `RetinalMarkers.fromJson` (and the on-device port's producer)
consume EXACTLY the field names, enum value strings, and nullability this
test pins. Any drift on the Python side fails here before it fails on a
rural operator's screen.

The Dart counterpart asserting the same shapes lives in
`flutter_app/test/evidence_payload_test.dart` (same example payload).
"""

import json

import numpy as np

from api.schemas import (
    ReviewMarkersResponse,
    criterion_evaluation_items,
    disagreement_assessment,
    lesion_evidence_items,
    policy_info,
)
from src.segmentation.structure_segmenter import RetinalStructureSegmenter
from src.services.disagreement import DisagreementStatus, reconcile
from src.services.evidence import (
    LesionType,
    fovea_involved_ids,
    normalize_structures,
)
from src.services.grading_policy import (
    CriterionId,
    CriterionStatus,
    evaluate_criteria,
)


def _synthetic_fundus() -> np.ndarray:
    img = np.zeros((480, 640, 3), dtype=np.uint8)
    import cv2

    cv2.circle(img, (320, 240), 200, (60, 30, 35), -1)
    cv2.circle(img, (240, 240), 28, (240, 210, 170), -1)
    cv2.line(img, (240, 240), (400, 180), (25, 14, 18), 2, cv2.LINE_AA)
    cv2.line(img, (240, 240), (180, 340), (25, 14, 18), 2, cv2.LINE_AA)
    for x, y in ((300, 150), (260, 350)):
        cv2.circle(img, (x, y), 2, (45, 10, 25), -1)
    return img


def _full_payload() -> dict:
    img = _synthetic_fundus()
    result = RetinalStructureSegmenter().segment_structures(img)
    landmarks, lesions, detector_status = normalize_structures(img, result)
    fovea_ids, fovea_evaluable = fovea_involved_ids(lesions, landmarks, result)
    ma_failed = not detector_status["classical_cv_segmenter"].ran
    exudate_failed = not detector_status["classical_cv_segmenter:exudate"].ran
    policy = evaluate_criteria(
        ma_evidence_ids=tuple(
            l.lesion_id for l in lesions if l.lesion_type == LesionType.MICROANEURYSM_CANDIDATE
        ),
        exudate_evidence_ids=tuple(
            l.lesion_id for l in lesions if l.lesion_type == LesionType.EXUDATE_CANDIDATE
        ),
        fovea_involved_ids=tuple(fovea_ids),
        ma_detector_failed=ma_failed,
        exudate_detector_failed=exudate_failed,
        fovea_evaluable=fovea_evaluable,
    )
    disagreement = reconcile(
        cnn_grade=1,
        implied_grade=policy.implied.implied_grade,
        implied_status=policy.implied.implied_status.value,
        any_detector_failed=ma_failed or exudate_failed,
    )
    payload = ReviewMarkersResponse(
        review_id="REV-WIRE-1",
        available=True,
        width=int(img.shape[1]),
        height=int(img.shape[0]),
        ma_candidates=[],
        lesion_evidence=lesion_evidence_items(lesions),
        criteria_evaluation=criterion_evaluation_items(policy.criteria),
        grading_policy=policy_info(policy),
        disagreement=disagreement_assessment(disagreement),
    )
    return json.loads(payload.model_dump_json())


def test_wire_field_names_match_dart_fromJson():
    body = _full_payload()
    assert set(body.keys()) == {
        "review_id",
        "available",
        "reason",
        "source",
        "width",
        "height",
        "optic_disc",
        "fovea",
        "ma_candidates",
        "schema_version",
        "lesion_evidence",
        "criteria_evaluation",
        "grading_policy",
        "disagreement",
    }


def test_lesion_evidence_wire_shape():
    body = _full_payload()
    for item in body["lesion_evidence"]:
        assert set(item.keys()) == {
            "lesion_id",
            "lesion_type",
            "detection_status",
            "x",
            "y",
            "radius",
            "geometry_type",
            "detector_id",
            "detector_version",
            "criterion_links",
            "evidence_notes",
            "image_width",
            "image_height",
        }
        assert item["lesion_id"].startswith("LE-")
        # StrEnum values serialize as plain strings (Dart parses strings).
        assert isinstance(item["lesion_type"], str)
        assert item["lesion_type"] in {
            "microaneurysm_candidate",
            "exudate_candidate",
            "hemorrhage_candidate",
        }
        assert item["detection_status"] in {
            "detected",
            "indeterminate",
            "not_evaluated",
            "failed",
        }
        assert all(
            isinstance(item[k], int) for k in ("x", "y", "radius", "image_width", "image_height")
        )
        assert all(isinstance(v, str) for v in item["criterion_links"])
        assert all(isinstance(v, str) for v in item["evidence_notes"])


def test_criteria_evaluation_wire_shape():
    body = _full_payload()
    ids = {c["criterion_id"] for c in body["criteria_evaluation"]}
    assert ids == {
        CriterionId.MA_PRESENT.value,
        CriterionId.EXUDATE_PRESENT.value,
        CriterionId.FOVEA_INVOLVEMENT.value,
        CriterionId.VENOUS_BEADING.value,
        CriterionId.NEOVASCULARIZATION.value,
    }
    for c in body["criteria_evaluation"]:
        assert c["status"] in {s.value for s in CriterionStatus}
        assert set(c.keys()) == {
            "criterion_id",
            "status",
            "supporting_evidence_ids",
            "contradicting_evidence_ids",
            "reason_codes",
            "explanation_key",
        }


def test_ids_resolve_across_sections():
    body = _full_payload()
    evidence_ids = {e["lesion_id"] for e in body["lesion_evidence"]}
    linked_ids = {eid for c in body["criteria_evaluation"] for eid in c["supporting_evidence_ids"]}
    assert linked_ids.issubset(evidence_ids), (
        "every criterion link must resolve to a real evidence object"
    )


def test_disagreement_wire_shape():
    body = _full_payload()
    d = body["disagreement"]
    assert set(d.keys()) == {
        "status",
        "reason_codes",
        "review_required",
        "cnn_grade",
        "evidence_implied_grade",
        "explanation_key",
        "policy_id",
        "policy_version",
    }
    assert d["status"] in {s.value for s in DisagreementStatus}
    assert d["cnn_grade"] == 1  # stored CNN grade preserved verbatim
    assert d["policy_version"] == "1.0"


def test_policy_info_wire_shape():
    body = _full_payload()
    p = body["grading_policy"]
    assert set(p.keys()) == {"policy_id", "policy_version", "framework"}
    assert p["policy_id"] == "icdrss-subset"
    assert body["schema_version"] == "1.0"
