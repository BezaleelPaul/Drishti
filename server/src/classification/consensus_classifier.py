"""Dual-Engine Consensus Classifier (DRDetect CNN + Meta DINOv3-Large ViT).

Combines:
1. DRDetect Ordinal Regression ONNX (EfficientNet-B0) — High rotation stability, continuous scoring.
2. Meta DINOv3-Large (ViT-Large 300M) with 4-view TTA — High feature discrimination, glare/contrast immunity.

When both engines agree on the clinical triage tier (Clean, Mild, or Referable):
- Consensus is achieved, and automated reporting proceeds with elevated confidence.

When the engines disagree (e.g., optical glare fooled the CNN, or rotation fooled the ViT):
- The consensus engine flags an epistemic disagreement and halts automated decision release,
  safely escalating the scan for mandatory clinician tele-review.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import logging
import os
import sys

import numpy as np
from PIL import Image

from src.classification.classifier import DRClassifier
from src.classification.dinov3_classifier import DINOv3ICDRClassifier
from src.classification.retfound_classifier import RETFoundDRClassifier
from src.pipeline.schema import DRClassificationResult, DRGrade

logger = logging.getLogger(__name__)

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@dataclass
class ConsensusReport:
    """Detailed diagnostics from the dual-engine consensus evaluation."""

    consensus_achieved: bool
    status: str  # 'CONSENSUS' or 'DISAGREEMENT'
    drdetect_grade: int
    drdetect_score: float
    dinov3_class: int
    dinov3_probabilities: list[float]
    triage_tier: int  # 0: Clean, 1: Mild, 2: Referable
    triage_label: str
    combined_confidence: float
    disagreement_reason: str | None = None
    tta_views_used: int = 4
    vit_backend: str = "dinov3"
    model_id: str = "dual_engine_consensus"


class DualEngineConsensusClassifier:
    """Orchestrates concurrent inference across DRDetect and ViT (DINOv3 or RETFound)."""

    TRIAGE_LABELS = (
        "No Diabetic Retinopathy (Clean / Normal)",
        "Mild Diabetic Retinopathy (Non-Referable)",
        "Referable Diabetic Retinopathy (Grade 2+ / Urgent)",
    )

    def __init__(
        self,
        onnx_model_path: str | None = None,
        dinov3_checkpoint_path: str | None = None,
        retfound_checkpoint_path: str | None = None,
        vit_backend: str = "dinov3",
        device: str = "cpu",
        use_tta: bool = True,
    ):
        self.device = device
        self.use_tta = use_tta
        self.vit_backend = vit_backend.lower()

        # 1. DRDetect ONNX
        default_onnx = os.path.join(
            _REPO_ROOT, "models", "efficientnet_b0_regression_512px.onnx"
        )
        self.onnx_path = onnx_model_path or default_onnx
        self.clf_onnx = DRClassifier(onnx_model_path=self.onnx_path, device=self.device)

        # 2. Vision Transformer Engine (DINOv3 or RETFound)
        self.clf_vit: Any = None
        if self.vit_backend == "retfound":
            self.clf_vit = RETFoundDRClassifier(
                checkpoint_path=retfound_checkpoint_path,
                device=self.device,
                use_tta=self.use_tta,
            )
            self.clf_dinov3 = self.clf_vit
            vit_name = "RETFound-MAE"
        else:
            default_dinov3 = os.path.join(
                _REPO_ROOT, "models", "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth"
            )
            self.dinov3_path = dinov3_checkpoint_path or default_dinov3
            self.clf_dinov3 = DINOv3ICDRClassifier(
                checkpoint_path=self.dinov3_path, device=self.device
            )
            self.clf_vit = self.clf_dinov3
            vit_name = f"DINOv3 ({os.path.basename(self.dinov3_path)})"

        logger.info(
            "Initialized DualEngineConsensusClassifier [DRDetect: %s, ViT: %s, Backend: %s, TTA: %s]",
            os.path.basename(self.onnx_path),
            vit_name,
            self.vit_backend,
            self.use_tta,
        )

    def predict(
        self, image_input: str | np.ndarray | Image.Image
    ) -> DRClassificationResult:
        """Executes dual-engine evaluation and returns a schema-compliant DRClassificationResult."""
        report = self.evaluate_consensus(image_input)

        # Map to standard 5-class schema for downstream pipeline compatibility
        grade_mapping = {
            0: DRGrade.NO_DR,
            1: DRGrade.MILD_NPDR,
            2: DRGrade.MODERATE_NPDR,
        }
        pred_grade = grade_mapping.get(report.triage_tier, DRGrade.NO_DR)

        # In case of disagreement, project conservative probabilities and lower the margin
        # to ensure the ConfidenceEvaluator triggers mandatory human review.
        if report.consensus_achieved:
            conf = float(report.combined_confidence)
            margin = 0.40  # decisive margin
            uncertainty = float(1.0 - conf)
            p0 = 1.0 - conf if report.triage_tier != 0 else conf
            p1 = conf if report.triage_tier == 1 else (1.0 - conf) / 2.0
            p2 = conf if report.triage_tier == 2 else (1.0 - conf) / 2.0
        else:
            conf = float(report.combined_confidence)
            margin = 0.05  # narrow margin triggers ambiguity flag
            uncertainty = 0.95  # high epistemic uncertainty
            p0 = 0.33
            p1 = 0.34
            p2 = 0.33

        five_class_probs = [
            float(p0),
            float(p1),
            float(p2 / 3.0),
            float(p2 / 3.0),
            float(p2 / 3.0),
        ]

        # Normalization
        tot = sum(five_class_probs)
        if tot > 0:
            five_class_probs = [p / tot for p in five_class_probs]

        is_ref = bool(report.triage_tier == 2 or report.drdetect_score >= 1.5)

        return DRClassificationResult(
            predicted_grade=pred_grade,
            probabilities=five_class_probs,
            confidence=conf,
            top2_margin=margin,
            is_referable=is_ref,
            raw_score=float(report.drdetect_score),
            uncertainty=uncertainty,
            model_id=f"consensus_{report.status.lower()}",
        )

    def evaluate_consensus(
        self, image_input: str | np.ndarray | Image.Image
    ) -> ConsensusReport:
        """Runs both engines and computes detailed consensus diagnostics."""
        pil_img = self._to_pil(image_input)

        # 1. DRDetect prediction
        res_onnx = self.clf_onnx.predict(pil_img)
        onnx_score = float(res_onnx.raw_score if res_onnx.raw_score is not None else 0.0)
        onnx_grade = int(res_onnx.predicted_grade.value)

        # DRDetect Triage tier:
        # Tier 0: Grade 0 (Score < 0.5)
        # Tier 1: Grade 1 (0.5 <= Score < 1.5)
        # Tier 2: Referable (Score >= 1.5)
        if onnx_score < 0.5:
            onnx_tier = 0
        elif onnx_score < 1.5:
            onnx_tier = 1
        else:
            onnx_tier = 2

        # 2. Vision Transformer prediction (DINOv3 or RETFound)
        if self.vit_backend == "retfound":
            out_vit = self.clf_vit.predict(pil_img, use_tta=self.use_tta)
            vit_probs = out_vit.probabilities
            vit_class = out_vit.predicted_class
            vit_conf = out_vit.confidence
            # Map 5-class to 3 triage tiers: 0 -> 0, 1 -> 1, >=2 -> 2
            vit_tier = 0 if vit_class == 0 else (1 if vit_class == 1 else 2)
            vit_name = "RETFound"
        else:
            if self.use_tta:
                rot_logits = []
                for angle in (0, 90, 180, 270):
                    r_img = pil_img.rotate(angle) if angle != 0 else pil_img
                    r_out = self.clf_dinov3.predict(r_img)
                    rot_logits.append(r_out.raw_logits)
                avg_logits = np.mean(rot_logits, axis=0)
                exp_l = np.exp(avg_logits - np.max(avg_logits))
                vit_probs = [float(p) for p in (exp_l / np.sum(exp_l))]
                vit_class = int(np.argmax(vit_probs))
                vit_conf = float(vit_probs[vit_class])
            else:
                out_d = self.clf_dinov3.predict(pil_img)
                vit_probs = out_d.probabilities
                vit_class = out_d.predicted_class
                vit_conf = out_d.confidence
            vit_tier = vit_class  # DINOv3 is already 0, 1, 2
            vit_name = "DINOv3"

        # 3. Consensus Evaluation
        if onnx_tier == vit_tier:
            consensus = True
            status = "CONSENSUS"
            triage_tier = onnx_tier
            # Elevated confidence when both engines independently agree
            combined_conf = min(0.99, max(res_onnx.confidence, vit_conf) * 1.05)
            reason = None
        else:
            consensus = False
            status = "DISAGREEMENT"
            # In disagreement, adopt the higher clinical risk tier (safety-first / fail-safe)
            triage_tier = max(onnx_tier, vit_tier)
            combined_conf = 0.51  # Penalized confidence
            reason = (
                f"Dual-engine triage mismatch: DRDetect scored {onnx_score:.2f} (Tier {onnx_tier}) "
                f"while {vit_name} predicted Class {vit_class} (Tier {vit_tier}). "
                "Possible optical glare artifact, lesion near boundary, or non-retinal noise."
            )

        return ConsensusReport(
            consensus_achieved=consensus,
            status=status,
            drdetect_grade=onnx_grade,
            drdetect_score=onnx_score,
            dinov3_class=vit_class,
            dinov3_probabilities=vit_probs,
            triage_tier=triage_tier,
            triage_label=self.TRIAGE_LABELS[triage_tier],
            combined_confidence=combined_conf,
            disagreement_reason=reason,
            tta_views_used=4 if self.use_tta else 1,
            vit_backend=self.vit_backend,
        )

    def _to_pil(self, image_input: str | np.ndarray | Image.Image) -> Image.Image:
        if isinstance(image_input, str):
            return Image.open(image_input).convert("RGB")
        elif isinstance(image_input, np.ndarray):
            if image_input.dtype != np.uint8:
                if image_input.max() <= 1.0:
                    image_input = (image_input * 255.0).astype(np.uint8)
                else:
                    image_input = image_input.astype(np.uint8)
            return Image.fromarray(image_input).convert("RGB")
        elif isinstance(image_input, Image.Image):
            return image_input.convert("RGB")
        raise TypeError(f"Unsupported image input type: {type(image_input)}")
