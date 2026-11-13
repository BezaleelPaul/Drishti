"""Moorfields / Yukun Zhou RETFound Foundation Model for Diabetic Retinopathy.

Architecture:
- Backbone: RETFound ViT-Large (1024 embedding dim, 24 transformer blocks, 16x16 patch size)
  Pre-trained on 1.6+ million human retinal images (Color Fundus + OCT) via Masked Autoencoders (MAE).
- Classification Head: Linear(1024 -> 5) fine-tuned on multi-class ICDR/ETDRS Diabetic Retinopathy.
- Resolution: 256x256 RGB.

Classes:
  0 - No DR (ICDR 0)
  1 - Mild NPDR (ICDR 1)
  2 - Moderate NPDR (ICDR 2)
  3 - Severe NPDR (ICDR 3)
  4 - Proliferative DR (ICDR 4)
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

try:
    import timm
    HAS_TIMM = True
except ImportError:
    HAS_TIMM = False

logger = logging.getLogger(__name__)

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_DEFAULT_WEIGHTS_PATH = os.path.join(_REPO_ROOT, "models", "retfound_eyepacs_5class.pth")


@dataclass
class RETFoundOutput:
    """Diagnostic output from the RETFound foundation model."""

    predicted_class: int
    class_label: str
    probabilities: list[float]  # 5-class probability vector [P0..P4]
    confidence: float
    top2_margin: float
    is_referable: bool
    raw_logits: list[float]
    expected_severity_score: float  # Sum(i * P_i) continuous score [0.0 - 4.0]
    model_id: str = "retfound_vitl16_natureCFP"

    def to_dr_classification_result(self) -> DRClassificationResult:
        """Projects output onto Drishti-AI's canonical DRClassificationResult."""
        pred_grade = DRGrade(min(max(self.predicted_class, 0), 4))
        return DRClassificationResult(
            predicted_grade=pred_grade,
            probabilities=self.probabilities,
            confidence=self.confidence,
            top2_margin=self.top2_margin,
            is_referable=self.is_referable,
            raw_score=self.expected_severity_score,
            uncertainty=float(1.0 - self.confidence),
            model_id=self.model_id,
        )


class RETFoundDRClassifier:
    """Classifier utilizing Moorfields' RETFound medical foundation model."""

    CLASS_LABELS = (
        "No Diabetic Retinopathy (ICDR 0)",
        "Mild Non-Proliferative DR (ICDR 1)",
        "Moderate Non-Proliferative DR (ICDR 2)",
        "Severe Non-Proliferative DR (ICDR 3)",
        "Proliferative Diabetic Retinopathy (ICDR 4)",
    )

    HF_REPO_ID = "bswift/RETfound_eyepacs_DR"
    HF_WEIGHT_FILE = "pytorch_model.bin"

    def __init__(
        self,
        checkpoint_path: str | None = None,
        device: str | None = None,
        image_size: int = 256,
        model_name: str = "vit_large_patch16_224",
        use_tta: bool = True,
        auto_download: bool = False,
    ):
        self.image_size = image_size
        self.model_name = model_name
        self.use_tta = use_tta
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.checkpoint_path = checkpoint_path or _DEFAULT_WEIGHTS_PATH
        self.auto_download = auto_download
        self.model: nn.Module | None = None

        self._transform = transforms.Compose(
            [
                transforms.Resize((self.image_size, self.image_size)),
                transforms.ToTensor(),
                transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
            ]
        )
        self._init_model()

    def _init_model(self) -> None:
        """Initializes the RETFound ViT-Large backbone and loads weights if available."""
        if not HAS_TIMM:
            raise ImportError(
                "timm is required for RETFoundDRClassifier. Install with `pip install timm`."
            )

        # 1. Instantiate ViT architecture matching RETFound (defaults to vit_large_patch16_224)
        self.model = timm.create_model(
            self.model_name,
            img_size=self.image_size,
            num_classes=5,
            drop_path_rate=0.2,
        )

        # 2. Check if weights file exists locally
        if not os.path.exists(self.checkpoint_path) and self.auto_download:
            self._download_weights()

        if os.path.exists(self.checkpoint_path):
            try:
                ckpt = torch.load(self.checkpoint_path, map_location=self.device)
                state_dict = ckpt.get("model", ckpt)
                self.model.load_state_dict(state_dict, strict=False)
                logger.info("Loaded RETFound checkpoint from %s", self.checkpoint_path)
            except Exception as e:
                logger.warning(
                    "Could not load checkpoint from %s (%s). Running with initialized backbone.",
                    self.checkpoint_path,
                    e,
                )
        else:
            logger.info(
                "No RETFound weights found at %s. Classifier initialized with unweighted backbone.",
                self.checkpoint_path,
            )

        self.model.to(self.device)
        self.model.eval()

    def _download_weights(self) -> None:
        """Downloads fine-tuned RETFound weights from Hugging Face Hub."""
        try:
            from huggingface_hub import hf_hub_download

            logger.info("Downloading RETFound weights from %s...", self.HF_REPO_ID)
            os.makedirs(os.path.dirname(os.path.abspath(self.checkpoint_path)), exist_ok=True)
            dl_path = hf_hub_download(
                repo_id=self.HF_REPO_ID,
                filename=self.HF_WEIGHT_FILE,
                local_dir=os.path.dirname(self.checkpoint_path),
            )
            if dl_path != self.checkpoint_path:
                import shutil
                shutil.move(dl_path, self.checkpoint_path)
            logger.info("Successfully downloaded RETFound weights to %s", self.checkpoint_path)
        except Exception as e:
            logger.error("Failed to download RETFound weights: %s", e)

    def predict(
        self,
        image_input: str | np.ndarray | Image.Image,
        use_tta: bool | None = None,
    ) -> RETFoundOutput:
        """Runs inference with optional 4-view Test-Time Augmentation."""
        pil_img = self._to_pil(image_input)
        tta = self.use_tta if use_tta is None else use_tta

        if tta:
            logits_list = []
            for angle in (0, 90, 180, 270):
                r_img = pil_img.rotate(angle) if angle != 0 else pil_img
                t = self._transform(r_img).unsqueeze(0).to(self.device)
                with torch.no_grad():
                    logits_list.append(self.model(t).squeeze(0).cpu().numpy())
            avg_logits = np.mean(logits_list, axis=0)
        else:
            t = self._transform(pil_img).unsqueeze(0).to(self.device)
            with torch.no_grad():
                avg_logits = self.model(t).squeeze(0).cpu().numpy()

        exp_l = np.exp(avg_logits - np.max(avg_logits))
        probs = [float(p) for p in (exp_l / np.sum(exp_l))]
        pred_class = int(np.argmax(probs))

        sorted_probs = sorted(probs, reverse=True)
        margin = float(sorted_probs[0] - sorted_probs[1]) if len(sorted_probs) > 1 else float(probs[pred_class])
        conf = float(probs[pred_class])

        # Expected severity: E[Grade] = sum(i * P_i)
        expected_score = float(sum(i * p for i, p in enumerate(probs)))
        is_ref = pred_class >= 2 or expected_score >= 1.5

        return RETFoundOutput(
            predicted_class=pred_class,
            class_label=self.CLASS_LABELS[pred_class],
            probabilities=probs,
            confidence=conf,
            top2_margin=margin,
            is_referable=is_ref,
            raw_logits=[float(l) for l in avg_logits],
            expected_severity_score=round(expected_score, 3),
            model_id="retfound_vitl16_natureCFP",
        )

    def export_torchscript(self, save_path: str) -> str:
        """Traces and exports the RETFound model to TorchScript (.pt)."""
        os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
        dummy_input = torch.zeros(1, 3, self.image_size, self.image_size, device=self.device)
        self.model.eval()
        with torch.no_grad():
            traced = torch.jit.trace(self.model, dummy_input)
            traced.save(save_path)
        logger.info("Exported TorchScript RETFound model to %s", save_path)
        return save_path

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
