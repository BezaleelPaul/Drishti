"""Unit tests for evidence normalization + coordinate integrity.

Coordinate contract under test: SOURCE-image pixel space, origin top-left,
x in [0, width), y in [0, height). Fixtures are SYNTHETIC numpy arrays
exercising the real segmenter + normalizer (never stubs).
"""

import cv2
import numpy as np
import pytest

from src.segmentation.structure_segmenter import RetinalStructureSegmenter
from src.services.evidence import (
    DETECTOR_ID,
    DETECTOR_VERSION,
    DetectionStatus,
    LesionType,
    fovea_involved_ids,
    normalize_structures,
)

W, H = 640, 480


def _fundus_with_dark_dots(dots: list[tuple[int, int]]) -> np.ndarray:
    """Proven synthetic geometry (mirrors test_review_markers_service):
    black background, red fundus disc, darker vessel strokes, MA-like dots."""
    img = np.zeros((H, W, 3), dtype=np.uint8)
    cv2.circle(img, (320, 240), 200, (60, 30, 35), -1)
    cv2.circle(img, (240, 240), 28, (240, 210, 170), -1)
    cv2.line(img, (240, 240), (400, 180), (25, 14, 18), 2, cv2.LINE_AA)
    cv2.line(img, (240, 240), (180, 340), (25, 14, 18), 2, cv2.LINE_AA)
    for x, y in dots:
        cv2.circle(img, (x, y), 2, (45, 10, 25), -1)
    return img


@pytest.fixture(scope="module")
def segmenter():
    return RetinalStructureSegmenter()


def test_coordinates_always_within_source_image_bounds(segmenter):
    img = _fundus_with_dark_dots([(300, 200), (350, 260), (250, 150)])
    res = segmenter.segment_structures(img)
    landmarks, lesions, _ = normalize_structures(img, res)
    for l in landmarks:
        assert 0 <= l.x < W
        assert 0 <= l.y < H
    for l in lesions:
        assert 0 <= l.x < W
        assert 0 <= l.y < H


def test_malformed_coordinates_fail_closed(segmenter, monkeypatch):
    img = _fundus_with_dark_dots([])
    res = segmenter.segment_structures(img)
    res.optic_disc_center = (99999, 99999)  # out of bounds
    with pytest.raises(ValueError, match="outside image bounds"):
        normalize_structures(img, res)


def test_non_finite_coordinates_fail_closed(segmenter):
    img = _fundus_with_dark_dots([])
    res = segmenter.segment_structures(img)
    res.fovea_center = (float("nan"), 10)
    with pytest.raises(ValueError):
        normalize_structures(img, res)


def test_invalid_image_shape_fails_closed(segmenter):
    img = _fundus_with_dark_dots([])
    res = segmenter.segment_structures(img)
    with pytest.raises(ValueError, match="HxWx3"):
        normalize_structures(np.zeros((5, 5)), res)


def test_lesion_ids_are_stable_and_unique(segmenter):
    img = _fundus_with_dark_dots([(300, 200), (350, 260), (250, 150)])
    res = segmenter.segment_structures(img)
    _, lesions, _ = normalize_structures(img, res)
    ids = [l.lesion_id for l in lesions]
    assert len(ids) == len(set(ids))
    for i, lid in enumerate(ids):
        assert lid == f"LE-{i + 1:04d}"


def test_lesion_types_and_links(segmenter):
    img = _fundus_with_dark_dots([(300, 200), (350, 260)])
    res = segmenter.segment_structures(img)
    _, lesions, _ = normalize_structures(img, res)
    assert lesions, "synthetic MA dots must produce candidates"
    for l in lesions:
        assert l.detector_id == DETECTOR_ID
        assert l.detector_version == DETECTOR_VERSION
        assert l.geometry_type == "circle"
        assert "icdrss.ma_present" in l.criterion_links
        assert l.detection_status == DetectionStatus.DETECTED
        # Candidates carry the honesty caveat note.
        assert any("not a confirmed lesion" in n for n in l.evidence_notes)
    assert all(l.lesion_type == LesionType.MICROANEURYSM_CANDIDATE for l in lesions)


def test_no_candidates_vs_available_state_distinction(segmenter):
    # Clean fundus (no dots): valid run with zero lesions — NOT a failure.
    img = _fundus_with_dark_dots([])
    res = segmenter.segment_structures(img)
    landmarks, lesions, statuses = normalize_structures(img, res)
    assert lesions == []
    assert landmarks  # landmarks still present
    assert statuses[DETECTOR_ID].ran is True
    assert statuses[DETECTOR_ID].failed is False


def test_exudate_mask_without_opencv_yields_not_ran_status(segmenter, monkeypatch):
    import src.segmentation.structure_segmenter as seg_module

    monkeypatch.setattr(seg_module, "HAS_OPENCV", False)
    img = _fundus_with_dark_dots([])
    res = seg_module.RetinalStructureSegmenter().segment_structures(img)
    _, _, statuses = normalize_structures(img, res)
    assert statuses[DETECTOR_ID].ran is False
    assert statuses[DETECTOR_ID].failed is True


def test_fovea_involvement_spatial_rule(segmenter):
    # Dots: one near the geometric fovea region, one far temporal side.
    img = _fundus_with_dark_dots([(300, 200), (100, 100)])
    res = segmenter.segment_structures(img)
    landmarks, lesions, _ = normalize_structures(img, res)
    ids, evaluable = fovea_involved_ids(lesions, landmarks, res)
    assert evaluable is True
    assert len(ids) <= len(lesions)
    # Every returned id must actually be one of the lesion ids.
    assert set(ids).issubset({l.lesion_id for l in lesions})


def test_fovea_rule_not_evaluable_with_degenerate_od(segmenter):
    img = _fundus_with_dark_dots([(300, 200)])
    res = segmenter.segment_structures(img)
    landmarks, lesions, _ = normalize_structures(img, res)
    # Zero-radius OD -> unreliable -> spatial rule not evaluable.
    for l in landmarks:
        if l.landmark_type == "optic_disc":
            od = l
    degenerate = type(od)(
        landmark_id=od.landmark_id,
        landmark_type=od.landmark_type,
        x=od.x,
        y=od.y,
        radius=0,
        reliable=False,
    )
    ids, evaluable = fovea_involved_ids(
        lesions, [degenerate, next(l for l in landmarks if l.landmark_type == "fovea")], res
    )
    assert evaluable is False
    assert ids == []
