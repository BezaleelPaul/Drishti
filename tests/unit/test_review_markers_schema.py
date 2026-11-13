"""Unit tests for the clinician review marker payload contract (ReviewMarkersResponse)."""

import pytest
from pydantic import ValidationError

from api.schemas import ReviewMarkersResponse


def test_available_payload_carries_coordinates_dimensions_and_provenance():
    payload = ReviewMarkersResponse(
        review_id="REV-8F3A21C0B4D7",
        available=True,
        reason=None,
        width=2240,
        height=1680,
        optic_disc={"x": 412, "y": 862, "r": 168},
        fovea={"x": 1385, "y": 805},
        ma_candidates=[
            {"x": 1204, "y": 733, "r": 6},
            {"x": 1310, "y": 921, "r": 4},
            {"x": 1088, "y": 860, "r": 5},
        ],
    )

    assert payload.available is True
    assert payload.reason is None
    assert payload.source == "classical_cv_segmentation"
    assert payload.width == 2240
    assert payload.height == 1680
    assert (payload.optic_disc.x, payload.optic_disc.y, payload.optic_disc.r) == (412, 862, 168)
    assert (payload.fovea.x, payload.fovea.y) == (1385, 805)
    assert len(payload.ma_candidates) == 3
    assert (payload.ma_candidates[0].x, payload.ma_candidates[0].y, payload.ma_candidates[0].r) == (
        1204,
        733,
        6,
    )


def test_available_payload_with_no_candidates_is_empty_not_unavailable():
    payload = ReviewMarkersResponse(
        review_id="REV-1B2C3D4E5F60",
        available=True,
        reason="No microaneurysm candidates found",
        width=2240,
        height=1680,
        optic_disc={"x": 412, "y": 862, "r": 168},
        fovea={"x": 1385, "y": 805},
        ma_candidates=[],
    )

    assert payload.available is True
    assert payload.ma_candidates == []
    assert payload.optic_disc is not None
    assert payload.fovea is not None


def test_unavailable_payload_has_reason_and_no_coordinates():
    payload = ReviewMarkersResponse(
        review_id="REV-0A1B2C3D4E5F",
        available=False,
        reason="Fundus image could not be decoded",
    )

    assert payload.available is False
    assert payload.reason == "Fundus image could not be decoded"
    assert payload.source == "classical_cv_segmentation"
    assert payload.optic_disc is None
    assert payload.fovea is None
    assert payload.ma_candidates == []
    assert payload.width == 0
    assert payload.height == 0


def test_source_cannot_override_provenance():
    # Req 2.2: provenance is structurally pinned to classical CV segmentation.
    # A dishonest payload (model attention, Grad-CAM, a diagnosis) must be
    # rejected by the schema itself, not merely defaulted-and-trusted.
    for dishonest_source in ("model attention", "grad_cam", "grad-cam", "diagnosis", ""):
        with pytest.raises(ValidationError):
            ReviewMarkersResponse(
                review_id="REV-X",
                available=True,
                source=dishonest_source,
            )

    default_payload = ReviewMarkersResponse(review_id="REV-X", available=True)
    assert default_payload.source == "classical_cv_segmentation"


def test_empty_candidates_and_unavailable_are_distinct_states():
    empty = ReviewMarkersResponse(
        review_id="REV-1B2C3D4E5F60",
        available=True,
        reason="No microaneurysm candidates found",
        width=1440,
        height=1080,
        optic_disc={"x": 300, "y": 640, "r": 120},
        fovea={"x": 900, "y": 520},
        ma_candidates=[],
    )
    unavailable = ReviewMarkersResponse(
        review_id="REV-0A1B2C3D4E5F",
        available=False,
        reason="Segmentation timed out",
    )

    empty_dump = empty.model_dump()
    unavailable_dump = unavailable.model_dump()

    # Serialized contract: empty candidates are an explicit list in BOTH
    # states — a null would let a client render "unknown" and collapse the
    # distinction between "computed, none found" and "not computed".
    assert isinstance(empty_dump["ma_candidates"], list)
    assert isinstance(unavailable_dump["ma_candidates"], list)
    assert empty_dump["ma_candidates"] == []
    assert unavailable_dump["ma_candidates"] == []

    # Available-empty still proves successful computation: geometry exists.
    assert empty_dump["optic_disc"] is not None
    assert empty_dump["fovea"] is not None
    assert empty_dump["width"] > 0
    assert empty_dump["height"] > 0

    # Unavailable carries zero coordinate values anywhere in the payload.
    assert unavailable_dump["optic_disc"] is None
    assert unavailable_dump["fovea"] is None
    assert unavailable_dump["width"] == 0
    assert unavailable_dump["height"] == 0

    # The two states must remain client-distinguishable even if a caller
    # ever wrote the same reason text into both — the distinction lives in
    # available + geometry, not in prose.
    empty_shape = {k: v for k, v in empty_dump.items() if k != "reason"}
    unavailable_shape = {k: v for k, v in unavailable_dump.items() if k != "reason"}
    assert empty_shape != unavailable_shape


def test_payload_serializes_marker_fields_and_no_mask_data():
    unavailable = ReviewMarkersResponse(
        review_id="REV-0A1B2C3D4E5F",
        available=False,
        reason="No retrievable fundus image",
    )
    dumped = unavailable.model_dump()

    assert dumped["ma_candidates"] == []
    assert dumped["optic_disc"] is None
    assert dumped["fovea"] is None
    for forbidden in (
        "vessel_mask",
        "exudate_mask",
        "annotated_overlay",
        "vessel_density_pct",
        "gradcam",
    ):
        assert forbidden not in dumped
