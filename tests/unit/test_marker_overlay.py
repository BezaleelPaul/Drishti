"""Unit tests for Diagnostic Lesion and Landmark Marker Visualizer."""
import os
import tempfile
import numpy as np
import pytest
from PIL import Image

from src.reporting.marker_overlay import RetinalMarkerVisualizer
from src.services.csme_engine import CSMERiskLevel, CSMERiskResult
from src.synthetic_fixtures import create_synthetic_fundus_image


@pytest.fixture
def visualizer():
    return RetinalMarkerVisualizer()


def test_draw_diagnostic_overlay_dimensions_and_dtype(visualizer):
    """Overlay output must preserve exact input spatial dimensions as uint8 RGB."""
    img = create_synthetic_fundus_image(size=(300, 300))
    overlay = visualizer.draw_diagnostic_overlay(img)

    assert isinstance(overlay, np.ndarray)
    assert overlay.dtype == np.uint8
    assert overlay.shape == (300, 300, 3)


def test_draw_diagnostic_overlay_with_csme_result(visualizer):
    """Overlay with an explicit CSME result displays correct annotations and HUD."""
    img = create_synthetic_fundus_image()
    mock_csme = CSMERiskResult(
        risk_level=CSMERiskLevel.HIGH_RISK_URGENT,
        urgent_referral=True,
        nearest_exudate_dd=0.35,
        exudates_detected_count=3,
        fovea_center=(128, 128),
        optic_disc_diameter_px=48.0,
        clinical_rationale="Urgent CSME",
    )

    overlay = visualizer.draw_diagnostic_overlay(
        img,
        csme_result=mock_csme,
        show_etdrs_grid=True,
        show_hud=True,
    )

    assert overlay.shape == img.shape
    # Bottom HUD region must be modified by the banner
    h, w = img.shape[:2]
    hud_region = overlay[h - 30 : h, :, :]
    orig_region = img[h - 30 : h, :, :]
    assert not np.array_equal(hud_region, orig_region)


def test_save_diagnostic_overlay_to_disk(visualizer):
    """save_diagnostic_overlay properly writes the image file to disk."""
    img = create_synthetic_fundus_image()
    with tempfile.TemporaryDirectory() as tmp_dir:
        out_path = os.path.join(tmp_dir, "overlay_test.png")
        saved_path = visualizer.save_diagnostic_overlay(img, save_path=out_path)

        assert os.path.exists(saved_path)
        assert os.path.getsize(saved_path) > 0

        # Verify loadable by PIL
        loaded = Image.open(saved_path)
        assert loaded.size == (img.shape[1], img.shape[0])


def test_pil_fallback_rendering(visualizer):
    """Pure-PIL drawing fallback produces valid RGB array."""
    img = create_synthetic_fundus_image()
    structs = visualizer.segmenter.segment_structures(img)
    csme = visualizer.csme_engine.evaluate(img, landmarks=structs)

    pil_overlay = visualizer._draw_pil(
        rgb_img=img,
        structs=structs,
        csme=csme,
        show_vessels=True,
        show_optic_disc=True,
        show_fovea=True,
        show_etdrs_grid=True,
        show_lesions=True,
        show_hud=True,
    )

    assert isinstance(pil_overlay, np.ndarray)
    assert pil_overlay.dtype == np.uint8
    assert pil_overlay.shape == img.shape
