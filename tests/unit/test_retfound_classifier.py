"""Unit tests for Moorfields RETFound 5-Class Foundation Model."""
from __future__ import annotations

import os
import numpy as np
import pytest
import torch
from PIL import Image

from src.classification.retfound_classifier import (
    RETFoundDRClassifier,
    RETFoundOutput,
)
from src.pipeline.schema import DRClassificationResult, DRGrade


def test_retfound_output_projection():
    """Validates projection from 5-class RETFound output to DRClassificationResult."""
    output = RETFoundOutput(
        predicted_class=3,
        class_label="Severe Non-Proliferative DR (ICDR 3)",
        probabilities=[0.02, 0.05, 0.15, 0.65, 0.13],
        confidence=0.65,
        top2_margin=0.50,
        is_referable=True,
        raw_logits=[-1.0, 0.0, 1.2, 3.5, 1.0],
        expected_severity_score=2.82,
        model_id="retfound_vitl16_natureCFP",
    )

    dr_res = output.to_dr_classification_result()
    assert isinstance(dr_res, DRClassificationResult)
    assert dr_res.predicted_grade == DRGrade.SEVERE_NPDR
    assert dr_res.is_referable is True
    assert dr_res.confidence == 0.65
    assert len(dr_res.probabilities) == 5
    assert dr_res.raw_score == 2.82


def test_retfound_classifier_architecture_and_forward(tmp_path):
    """Verifies that the RETFound ViT backbone initializes and runs forward inference."""
    import gc

    classifier = RETFoundDRClassifier(
        checkpoint_path=str(tmp_path / "dummy_weights.pth"),
        model_name="vit_tiny_patch16_224",
        device="cpu",
        use_tta=False,
        auto_download=False,
    )

    assert classifier.model is not None
    dummy_img = Image.new("RGB", (256, 256), color=(100, 150, 200))
    res = classifier.predict(dummy_img)

    assert isinstance(res, RETFoundOutput)
    assert 0 <= res.predicted_class <= 4
    assert len(res.probabilities) == 5
    assert sum(res.probabilities) == pytest.approx(1.0, abs=1e-4)
    assert 0.0 <= res.confidence <= 1.0
    assert 0.0 <= res.expected_severity_score <= 4.0

    del classifier
    gc.collect()


def test_retfound_torchscript_export(tmp_path):
    """Verifies that the RETFound backbone can be traced into TorchScript without error."""
    import gc

    classifier = RETFoundDRClassifier(
        checkpoint_path=str(tmp_path / "dummy.pth"),
        model_name="vit_tiny_patch16_224",
        device="cpu",
        use_tta=False,
        auto_download=False,
    )
    ts_path = str(tmp_path / "retfound_traced.pt")
    exported = classifier.export_torchscript(ts_path)

    assert os.path.exists(exported)
    loaded_ts = torch.jit.load(exported)
    loaded_ts.eval()

    dummy_t = torch.randn(1, 3, 256, 256)
    with torch.no_grad():
        out = loaded_ts(dummy_t)
    assert out.shape == (1, 5)

    del classifier, loaded_ts
    gc.collect()
