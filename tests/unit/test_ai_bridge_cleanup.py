import io
from pathlib import Path

import pytest
from PIL import Image

from api.services import ai_bridge
from api.services.ai_bridge import AIBridge


class _ClinicalBackend:
    def get_backend(self):
        return "keras"


class _FailingRouter:
    def process_image(self, **_kwargs):
        raise RuntimeError("pipeline failed")


def test_invalid_image_is_rejected_before_result_directory_creation(tmp_path, monkeypatch):
    monkeypatch.setattr(ai_bridge, "_RESULTS_DIR", str(tmp_path))
    bridge = AIBridge.__new__(AIBridge)
    bridge.dr_classifier = _ClinicalBackend()

    with pytest.raises(ValueError, match="Invalid image file"):
        bridge.analyze_retina(b"not-an-image", patient_id="PT-TEST")

    assert list(Path(tmp_path).iterdir()) == []


def test_pipeline_failure_is_rejected_before_result_directory_creation(tmp_path, monkeypatch):
    monkeypatch.setattr(ai_bridge, "_RESULTS_DIR", str(tmp_path))
    bridge = AIBridge.__new__(AIBridge)
    bridge.dr_classifier = _ClinicalBackend()
    bridge.router = _FailingRouter()
    bridge._camera_checkers = {}
    bridge.quality_checker = object()

    image_buffer = io.BytesIO()
    Image.new("RGB", (8, 8), color="black").save(image_buffer, format="PNG")

    with pytest.raises(RuntimeError, match="pipeline failed"):
        bridge.analyze_retina(image_buffer.getvalue(), patient_id="PT-TEST")

    assert list(Path(tmp_path).iterdir()) == []