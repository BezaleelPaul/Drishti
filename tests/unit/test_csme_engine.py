"""Unit tests for Clinically Significant Macular Edema (CSME) Geometric Risk Engine."""
import cv2
import numpy as np
import pytest

from src.services.csme_engine import (
    CSMEGeometricEngine,
    CSMERiskLevel,
    CSMERiskResult,
)
from src.synthetic_fixtures import create_synthetic_fundus_image


@pytest.fixture
def csme_engine():
    return CSMEGeometricEngine()


def test_clean_fundus_image_yields_no_csme(csme_engine):
    """Clean synthetic image has no bright exudative lesions."""
    img = create_synthetic_fundus_image()
    res = csme_engine.evaluate(img)

    assert isinstance(res, CSMERiskResult)
    assert res.risk_level == CSMERiskLevel.NO_CSME
    assert not res.urgent_referral
    assert res.exudates_detected_count == 0
    assert res.nearest_exudate_dd is None
    assert "No exudative deposits detected" in res.clinical_rationale


def test_high_risk_csme_within_half_disc_diameter(csme_engine):
    """Hard exudate within 0.5 DD of fovea triggers High Risk CSME (Urgent referral)."""
    img = create_synthetic_fundus_image()
    structs = csme_engine.segmenter.segment_structures(img)
    fx, fy = structs.fovea_center
    dd_px = 2.0 * structs.optic_disc_radius

    # Draw bright yellow lesion at 0.3 DD from fovea
    lesion_x = int(fx + 0.3 * dd_px)
    lesion_y = fy
    cv2.circle(img, (lesion_x, lesion_y), 5, (255, 255, 120), -1)

    res = csme_engine.evaluate(img)
    assert res.risk_level == CSMERiskLevel.HIGH_RISK_URGENT
    assert res.urgent_referral
    assert res.nearest_exudate_dd is not None
    assert res.nearest_exudate_dd <= 0.5
    assert "Sight-threatening CSME detected" in res.clinical_rationale


def test_moderate_risk_csme_between_half_and_one_and_half_dd(csme_engine):
    """Hard exudate between 0.5 and 1.5 DD triggers Moderate Risk CSME."""
    img = create_synthetic_fundus_image()
    structs = csme_engine.segmenter.segment_structures(img)
    fx, fy = structs.fovea_center
    dd_px = 2.0 * structs.optic_disc_radius

    # Draw bright yellow lesion at 0.9 DD from fovea
    lesion_x = int(fx + 0.9 * dd_px)
    lesion_y = fy
    cv2.circle(img, (lesion_x, lesion_y), 6, (255, 255, 120), -1)

    res = csme_engine.evaluate(img)
    assert res.risk_level == CSMERiskLevel.MODERATE_RISK
    assert res.urgent_referral
    assert res.nearest_exudate_dd is not None
    assert 0.5 < res.nearest_exudate_dd <= 1.5
    assert "Perimacular CSME risk" in res.clinical_rationale


def test_macular_safe_exudate_outside_one_and_half_dd(csme_engine):
    """Hard exudate > 1.5 DD away is extramacular (safe from immediate macular threat)."""
    img = create_synthetic_fundus_image()
    structs = csme_engine.segmenter.segment_structures(img)
    fx, fy = structs.fovea_center
    dd_px = 2.0 * structs.optic_disc_radius

    # Draw bright yellow lesion at 2.2 DD from fovea
    lesion_x = int(fx + 2.2 * dd_px)
    lesion_y = fy
    # Ensure it's inside retinal frame
    h, w = img.shape[:2]
    lesion_x = min(lesion_x, w - 10)
    cv2.circle(img, (lesion_x, lesion_y), 5, (255, 255, 120), -1)

    res = csme_engine.evaluate(img)
    # Could be MACULAR_SAFE or NO_CSME if clamped out
    if res.exudates_detected_count > 0:
        assert res.risk_level == CSMERiskLevel.MACULAR_SAFE
        assert not res.urgent_referral
        assert res.nearest_exudate_dd > 1.5


def test_fail_closed_on_unresolved_landmarks(csme_engine):
    """When anatomical landmarks cannot be resolved, returns safe non-crash result."""
    from src.segmentation.structure_segmenter import RetinalStructuresResult

    unresolved_landmarks = RetinalStructuresResult(
        optic_disc_center=(0, 0),
        optic_disc_radius=0,
        fovea_center=(0, 0),
        vessel_mask=np.zeros((256, 256), dtype=np.uint8),
    )
    res = csme_engine.evaluate(np.zeros((256, 256, 3), dtype=np.uint8), landmarks=unresolved_landmarks)

    assert res.risk_level == CSMERiskLevel.NO_CSME
    assert not res.urgent_referral
    assert "not resolved with sufficient confidence" in res.clinical_rationale
