"""Meta DINOv3-Large 3-Class ICDR Diabetic Retinopathy Classifier.

Checkpointed model: TL_dinov3_large_fine_tune_3class_final_icdr_best.pth

Architecture:
- Backbone: Meta DINOv3 ViT-Large (1024 embedding dim, 24 transformer blocks, 16x16 patch size, RoPE 2D position embeddings, 4 storage tokens)
- Classification Head:
  - hidden_layers.0: Linear(1024 -> 128)
  - hidden_layers.1: ReLU()
  - hidden_layers.2: Dropout(0.2)
  - hidden_layers.3: BatchNorm1d(128)
  - classifier: Linear(128 -> 3)

Classes:
  0 - No DR (ICDR 0)
  1 - Non-Referable / Mild DR (ICDR 1)
  2 - Referable DR (ICDR 2+: Moderate, Severe, Proliferative)
"""
from __future__ import annotations

from dataclasses import dataclass
import logging
import os
import sys

import numpy as np
from PIL import Image
import torch
from torch import nn
from torchvision import transforms

from src.pipeline.schema import DRClassificationResult, DRGrade

logger = logging.getLogger(__name__)

# Ensure vendored dinov3 in external/ or ~/.cache can be resolved
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_EXTERNAL_DIR = os.path.join(_PROJECT_ROOT, "external")
_CACHE_HUB_DIR = os.path.expanduser("~/.cache/torch/hub/facebookresearch_dinov3_main")

for p in (_EXTERNAL_DIR, _CACHE_HUB_DIR):
    if os.path.exists(p) and p not in sys.path:
        sys.path.insert(0, p)


class DINOv3ModelArchitecture(nn.Module):
    """Encapsulates the exact network structure of the fine-tuned 3-class DINOv3-Large model."""

    def __init__(self, dinov3_backbone: nn.Module, num_classes: int = 3, dropout_rate: float = 0.2):
        super().__init__()
        # Matches state_dict key prefix: backbone.backbone.*
        self.backbone = nn.Module()
        self.backbone.backbone = dinov3_backbone
        self.hidden_layers = nn.Sequential(
            nn.Linear(1024, 128),
            nn.ReLU(),
            nn.Dropout(dropout_rate),
            nn.BatchNorm1d(128),
        )
        self.classifier = nn.Linear(128, num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        feats = self.backbone.backbone(x)
        h = self.hidden_layers(feats)
        return self.classifier(h)


@dataclass
class DINOv3ICDROutput:
    """Detailed output for 3-class ICDR inference."""

    predicted_class: int
    class_label: str
    probabilities: list[float]  # [p0, p1, p2]
    confidence: float
    is_referable: bool
    raw_logits: list[float]
    model_id: str = "dinov3_large_3class_icdr"

    def to_dr_classification_result(self) -> DRClassificationResult:
        """Projects 3-class prediction onto the 5-grade DRGrade schema used across Drishti-AI."""
        grade_mapping = {
            0: DRGrade.NO_DR,
            1: DRGrade.MILD_NPDR,
            2: DRGrade.MODERATE_NPDR,
        }
        pred_grade = grade_mapping.get(self.predicted_class, DRGrade.NO_DR)

        p0 = self.probabilities[0] if len(self.probabilities) > 0 else 0.0
        p1 = self.probabilities[1] if len(self.probabilities) > 1 else 0.0
        p2 = self.probabilities[2] if len(self.probabilities) > 2 else 0.0

        five_class_probs = [
            float(p0),
            float(p1),
            float(p2 / 3.0),
            float(p2 / 3.0),
            float(p2 / 3.0),
        ]

        sorted_probs = sorted(self.probabilities, reverse=True)
        margin = (
            float(sorted_probs[0] - sorted_probs[1])
            if len(sorted_probs) > 1
            else float(self.confidence)
        )

        return DRClassificationResult(
            predicted_grade=pred_grade,
            probabilities=five_class_probs,
            confidence=float(self.confidence),
            top2_margin=margin,
            is_referable=self.is_referable,
            raw_score=float(self.predicted_class),
            uncertainty=float(1.0 - self.confidence),
            model_id=self.model_id,
        )


class DINOv3ICDRClassifier:
    """Runner for DINOv3-Large 3-class ICDR fine-tuned model."""

    CLASS_LABELS = (
        "No DR (ICDR 0)",
        "Non-Referable / Mild DR (ICDR 1)",
        "Referable DR (ICDR 2+)",
    )

    DEFAULT_CHECKPOINT_NAME = "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth"
    DEFAULT_TORCHSCRIPT_NAME = "dinov3_large_icdr_traced.pt"

    def __init__(
        self,
        checkpoint_path: str | None = None,
        device: str | None = None,
        image_size: int = 224,
        use_torchscript: bool = False,
        torchscript_path: str | None = None,
    ):
        self.image_size = image_size
        self.device = self._resolve_device(device)
        self.use_torchscript = use_torchscript
        self.torchscript_path = torchscript_path
        self.checkpoint_path = checkpoint_path or (
            self._find_checkpoint() if not (use_torchscript and torchscript_path) else None
        )
        self.model: nn.Module | None = None
        self._transform = transforms.Compose(
            [
                transforms.Resize((self.image_size, self.image_size)),
                transforms.ToTensor(),
                transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
            ]
        )
        self._load_model()

    def _resolve_device(self, device: str | None) -> str:
        if device is not None:
            return device
        return "cuda" if torch.cuda.is_available() else "cpu"

    def _find_checkpoint(self) -> str:
        candidates = [
            os.path.join(_PROJECT_ROOT, "models", self.DEFAULT_CHECKPOINT_NAME),
            os.path.join(os.path.expanduser("~"), "Downloads", self.DEFAULT_CHECKPOINT_NAME),
            os.path.join(_PROJECT_ROOT, self.DEFAULT_CHECKPOINT_NAME),
        ]
        for c in candidates:
            if os.path.exists(c):
                return c
        raise FileNotFoundError(
            f"Checkpoint {self.DEFAULT_CHECKPOINT_NAME} not found in {candidates}"
        )

    def _load_model(self) -> None:
        if self.use_torchscript:
            ts_path = self.torchscript_path or os.path.join(
                _PROJECT_ROOT, "models", self.DEFAULT_TORCHSCRIPT_NAME
            )
            if os.path.exists(ts_path):
                try:
                    self.model = torch.jit.load(ts_path, map_location=self.device)
                    self.model.eval()
                    logger.info("Successfully loaded TorchScript DINOv3 model from %s", ts_path)
                    return
                except Exception as e:
                    logger.warning(
                        "Failed loading pre-traced TorchScript model from %s (%s). Falling back to eager checkpoint.",
                        ts_path,
                        e,
                    )

        try:
            # 1. Load backbone from vendored external/dinov3 or torch.hub
            try:
                from dinov3.hub.backbones import dinov3_vitl16

                backbone = dinov3_vitl16(pretrained=False)
            except Exception:
                backbone = torch.hub.load(
                    "facebookresearch/dinov3", "dinov3_vitl16", pretrained=False
                )

            # 2. Instantiate wrapper
            self.model = DINOv3ModelArchitecture(backbone, num_classes=3)

            # 3. Load checkpoint
            if not self.checkpoint_path:
                self.checkpoint_path = self._find_checkpoint()
            ckpt = torch.load(self.checkpoint_path, map_location=self.device)
            self.model.load_state_dict(ckpt, strict=True)
            self.model.to(self.device)
            self.model.eval()
            logger.info("Successfully loaded DINOv3 model from %s", self.checkpoint_path)

            # If torchscript was requested but pre-traced file did not exist, trace now
            if self.use_torchscript:
                logger.info("Tracing DINOv3 model into TorchScript on-the-fly...")
                dummy_input = torch.zeros(1, 3, self.image_size, self.image_size, device=self.device)
                with torch.no_grad():
                    traced = torch.jit.trace(self.model, dummy_input)
                    self.model = traced
                    logger.info("On-the-fly TorchScript tracing complete.")
        except Exception as e:
            logger.error("Failed to load DINOv3 model: %s", e)
            raise

    def export_torchscript(self, save_path: str | None = None) -> str:
        """Traces the active model with torch.jit.trace and exports it to a standalone .pt file."""
        if save_path is None:
            save_path = os.path.join(_PROJECT_ROOT, "models", self.DEFAULT_TORCHSCRIPT_NAME)

        os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
        dummy_input = torch.zeros(1, 3, self.image_size, self.image_size, device=self.device)

        was_training = self.model.training if hasattr(self.model, "training") else False
        self.model.eval()

        with torch.no_grad():
            traced_model = torch.jit.trace(self.model, dummy_input)
            traced_model.save(save_path)

        if was_training and hasattr(self.model, "train"):
            self.model.train()

        logger.info("Exported TorchScript DINOv3 model to %s", save_path)
        return save_path

    def predict(
        self,
        image_input: str | np.ndarray | Image.Image,
        use_tta: bool = False,
    ) -> DINOv3ICDROutput:
        pil_img = self._to_pil(image_input)

        if use_tta:
            # 4-view Test-Time Augmentation (0°, 90°, 180°, 270°)
            rot_logits = []
            for angle in (0, 90, 180, 270):
                r_img = pil_img.rotate(angle) if angle != 0 else pil_img
                tensor = self._transform(r_img).unsqueeze(0).to(self.device)
                with torch.no_grad():
                    l = self.model(tensor).squeeze(0).cpu().numpy()
                    rot_logits.append(l)
            raw_logits_np = np.mean(rot_logits, axis=0)
            exp_l = np.exp(raw_logits_np - np.max(raw_logits_np))
            probs = [float(p) for p in (exp_l / np.sum(exp_l))]
            raw_logits = [float(l) for l in raw_logits_np]
            pred_class = int(np.argmax(probs))
        else:
            tensor = self._transform(pil_img).unsqueeze(0).to(self.device)
            with torch.no_grad():
                logits = self.model(tensor)
                probs_t = torch.softmax(logits, dim=-1).squeeze(0)
                probs = [float(p) for p in probs_t.cpu().numpy()]
                raw_logits = [float(l) for l in logits.squeeze(0).cpu().numpy()]
                pred_class = int(torch.argmax(logits, dim=-1).item())

        conf = float(probs[pred_class])
        is_ref = pred_class == 2

        return DINOv3ICDROutput(
            predicted_class=pred_class,
            class_label=self.CLASS_LABELS[pred_class],
            probabilities=probs,
            confidence=conf,
            is_referable=is_ref,
            raw_logits=raw_logits,
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
