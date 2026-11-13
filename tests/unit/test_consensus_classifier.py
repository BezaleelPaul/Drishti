"""Unit tests for Dual-Engine Consensus Classifier."""
from __future__ import annotations

import os
import numpy as np
import pytest
from PIL import Image

from src.classification.classifier import DRClassifier
from src.classification.consensus_classifier import (
    ConsensusReport,
    DualEngineConsensusClassifier,
)
from src.pipeline.schema import DRClassificationResult, DRGrade

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_ONNX_PATH = os.path.join(_REPO_ROOT, "models", "efficientnet_b0_regression_512px.onnx")
_DINO_PATH = os.path.join(
    _REPO_ROOT, "models", "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth"
)


@pytest.mark.skipif(
    not (os.path.exists(_ONNX_PATH) and os.path.exists(_DINO_PATH)),
    reason="Pretrained model weights not present",
)
class TestDualEngineConsensus:
    @pytest.fixture(scope="class")
    def classifier(self):
        import gc
        clf = DualEngineConsensusClassifier(
            onnx_model_path=_ONNX_PATH,
            dinov3_checkpoint_path=_DINO_PATH,
            device="cpu",
            use_tta=False,  # faster for unit tests
        )
        yield clf
        del clf
        gc.collect()

    def test_consensus_prediction_schema(self, classifier):
        dummy_img = Image.new("RGB", (224, 224), color=(128, 64, 32))
        res = classifier.predict(dummy_img)

        assert isinstance(res, DRClassificationResult)
        assert isinstance(res.predicted_grade, DRGrade)
        assert len(res.probabilities) == 5
        assert sum(res.probabilities) == pytest.approx(1.0, abs=1e-4)
        assert res.model_id.startswith("consensus_")
        assert res.raw_score is not None

    def test_evaluate_consensus_report(self, classifier):
        dummy_img = Image.new("RGB", (224, 224), color=(128, 64, 32))
        report = classifier.evaluate_consensus(dummy_img)

        assert isinstance(report, ConsensusReport)
        assert report.status in ("CONSENSUS", "DISAGREEMENT")
        assert report.triage_tier in (0, 1, 2)
        assert 0.0 <= report.combined_confidence <= 1.0
        assert len(report.dinov3_probabilities) == 3

    def test_dr_classifier_consensus_mode_integration(self, classifier):
        clf = DRClassifier(
            use_consensus=True,
            consensus_classifier=classifier,
            device="cpu",
        )
        assert clf.get_backend() == "consensus"

        dummy_img = Image.new("RGB", (224, 224), color=(64, 64, 64))
        res = clf.predict(dummy_img)
        assert isinstance(res, DRClassificationResult)
        assert res.model_id.startswith("consensus_")
