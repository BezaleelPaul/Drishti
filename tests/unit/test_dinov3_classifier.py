"""Unit tests for DINOv3-Large 3-Class ICDR Model and DRClassifier integration."""
from __future__ import annotations

import os
import numpy as np
import pytest
import torch
from PIL import Image

from src.classification.classifier import DRClassifier
from src.classification.dinov3_classifier import (
    DINOv3ICDRClassifier,
    DINOv3ICDROutput,
    DINOv3ModelArchitecture,
)
from src.pipeline.schema import DRClassificationResult, DRGrade

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_CKPT_PATH = os.path.join(
    _REPO_ROOT, "models", "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth"
)


class DummyBackbone(torch.nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        batch_size = x.shape[0]
        return torch.ones((batch_size, 1024), dtype=x.dtype, device=x.device)


def test_dinov3_model_architecture_shapes():
    dummy_bb = DummyBackbone()
    model = DINOv3ModelArchitecture(dummy_bb, num_classes=3)
    model.eval()

    inp = torch.randn(2, 3, 224, 224)
    with torch.no_grad():
        out = model(inp)

    assert out.shape == (2, 3), f"Expected shape (2, 3), got {out.shape}"


def test_dinov3_output_projection_to_dr_classification_result():
    output = DINOv3ICDROutput(
        predicted_class=1,
        class_label="Non-Referable / Mild DR (ICDR 1)",
        probabilities=[0.1, 0.7, 0.2],
        confidence=0.7,
        is_referable=False,
        raw_logits=[0.0, 1.5, 0.5],
    )

    dr_result = output.to_dr_classification_result()
    assert isinstance(dr_result, DRClassificationResult)
    assert dr_result.predicted_grade == DRGrade.MILD_NPDR
    assert len(dr_result.probabilities) == 5
    assert sum(dr_result.probabilities) == pytest.approx(1.0, rel=1e-4)
    assert dr_result.is_referable is False
    assert dr_result.confidence == pytest.approx(0.7)
    assert dr_result.model_id == "dinov3_large_3class_icdr"


@pytest.mark.skipif(not os.path.exists(_CKPT_PATH), reason="DINOv3 checkpoint not installed")
def test_dinov3_real_checkpoint_inference():
    import gc

    classifier = DINOv3ICDRClassifier(checkpoint_path=_CKPT_PATH, device="cpu")
    dummy_img = Image.new("RGB", (224, 224), color=(128, 64, 32))

    res = classifier.predict(dummy_img)
    assert isinstance(res, DINOv3ICDROutput)
    assert res.predicted_class in (0, 1, 2)
    assert len(res.probabilities) == 3
    assert sum(res.probabilities) == pytest.approx(1.0, abs=1e-4)
    assert 0.0 <= res.confidence <= 1.0

    del classifier
    gc.collect()


@pytest.mark.skipif(not os.path.exists(_CKPT_PATH), reason="DINOv3 checkpoint not installed")
def test_dr_classifier_dinov3_backend_integration():
    import gc

    classifier = DRClassifier(dinov3_model_path=_CKPT_PATH, device="cpu")
    assert classifier.get_backend() == "dinov3"

    dummy_arr = np.zeros((224, 224, 3), dtype=np.uint8)
    res = classifier.predict(dummy_arr)

    assert isinstance(res, DRClassificationResult)
    assert isinstance(res.predicted_grade, DRGrade)
    assert len(res.probabilities) == 5
    assert sum(res.probabilities) == pytest.approx(1.0, abs=1e-4)
    assert res.model_id == "dinov3_large_3class_icdr"

    del classifier
    gc.collect()


def test_dinov3_torchscript_export_and_inference_parity(tmp_path):
    """Verifies TorchScript tracing maintains exact logit parity on DINOv3ModelArchitecture."""
    dummy_bb = DummyBackbone()
    model = DINOv3ModelArchitecture(dummy_bb, num_classes=3)
    model.eval()

    dummy_input = torch.randn(1, 3, 224, 224)
    with torch.no_grad():
        eager_logits = model(dummy_input)

    ts_path = str(tmp_path / "traced_test.pt")
    traced_model = torch.jit.trace(model, dummy_input)
    traced_model.save(ts_path)

    loaded_ts = torch.jit.load(ts_path)
    loaded_ts.eval()
    with torch.no_grad():
        ts_logits = loaded_ts(dummy_input)

    assert torch.allclose(eager_logits, ts_logits, atol=1e-5), "TorchScript logits diverged from eager logits!"

