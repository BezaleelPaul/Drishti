"""Research-only baseline and multimodal models for DR grading; not a diagnostic device.

Missingness convention (§3a):
mask = 1 indicates missing; mask = 0 indicates observed.
"""
from __future__ import annotations

import torch
from torch import nn
from torchvision.models import EfficientNet_B0_Weights, efficientnet_b0


class TemperatureScaler(nn.Module):
    """Post-hoc temperature scaling fitted strictly on validation logits (§6).

    Learns a scalar temperature T > 0 on validation logits using L-BFGS to minimize
    Negative Log-Likelihood (NLL). Calibrated probabilities are given by:
        p_i = softmax(z_i / T)
    """

    def __init__(self, init_temperature: float = 1.5):
        super().__init__()
        self.temperature = nn.Parameter(torch.ones(1) * init_temperature)

    def forward(self, logits: torch.Tensor) -> torch.Tensor:
        temp = self.temperature.clamp(min=0.05, max=10.0)
        return logits / temp

    def fit(self, val_logits: torch.Tensor, val_labels: torch.Tensor, max_iter: int = 50) -> float:
        """Fit temperature parameter T on validation logits without modifying backbone weights."""
        val_logits = val_logits.detach()
        val_labels = val_labels.detach()
        nll_criterion = nn.CrossEntropyLoss()
        optimizer = torch.optim.LBFGS([self.temperature], lr=0.01, max_iter=max_iter)

        def eval_loss():
            optimizer.zero_grad()
            scaled_logits = self.forward(val_logits)
            loss = nll_criterion(scaled_logits, val_labels)
            loss.backward()
            return loss

        optimizer.step(eval_loss)
        with torch.no_grad():
            self.temperature.clamp_(min=0.05, max=10.0)
        return float(self.temperature.item())


class ImageOnlyDRClassifier(nn.Module):
    """Configurable image encoder baseline for 5-grade DR classification (0-4).

    Supports lightweight EfficientNet-B0 (default) as well as foundation ViT/DINO backbones.
    """

    def __init__(self, num_grades: int = 5, pretrained: bool = True, backbone: str = "efficientnet_b0"):
        super().__init__()
        self.backbone_name = backbone
        if backbone == "efficientnet_b0":
            weights = EfficientNet_B0_Weights.DEFAULT if pretrained else None
            bb = efficientnet_b0(weights=weights)
            self.image_encoder = bb.features
            self.image_pool = nn.AdaptiveAvgPool2d(1)
            in_features = 1280
        elif backbone.startswith("dinov2") or backbone.startswith("dino"):
            hub_name = backbone if "_" in backbone else "dinov2_vits14"
            try:
                bb = torch.hub.load("facebookresearch/dinov2", hub_name, pretrained=pretrained)
                self.image_encoder = bb
                self.image_pool = nn.Identity()
                in_features = getattr(bb, "embed_dim", 384)
            except Exception as e:
                raise RuntimeError(f"Failed to initialize DINO backbone '{hub_name}': {e}") from e
        else:
            raise ValueError(f"Unsupported backbone '{backbone}'. Choose 'efficientnet_b0' or 'dinov2_*'.")

        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(in_features, 256),
            nn.ReLU(),
            nn.Dropout(0.25),
            nn.Linear(256, num_grades),
        )

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        if self.backbone_name == "efficientnet_b0":
            features = self.image_pool(self.image_encoder(image))
        else:
            features = self.image_encoder(image)
        return self.classifier(features)


class ClinicalOnlyDRClassifier(nn.Module):
    """MLP baseline operating purely on clinical features with explicit missingness masks."""

    def __init__(self, clinical_features: int, num_grades: int = 5):
        super().__init__()
        if clinical_features < 1:
            raise ValueError("clinical_features must be positive")
        self.clinical_features = clinical_features
        self.classifier = nn.Sequential(
            nn.Linear(clinical_features * 2, 64),
            nn.ReLU(),
            nn.Dropout(0.15),
            nn.Linear(64, 64),
            nn.ReLU(),
            nn.Dropout(0.15),
            nn.Linear(64, num_grades),
        )

    def forward(self, clinical: torch.Tensor) -> torch.Tensor:
        if not torch.jit.is_tracing():
            if clinical.ndim != 2 or clinical.shape[1] != self.clinical_features * 2:
                raise ValueError(
                    f"clinical input must have shape [batch, {self.clinical_features * 2}] "
                    f"containing [imputed_values, missingness_mask (1=missing, 0=observed)]"
                )
        return self.classifier(clinical)


class RetinalClinicalFusion(nn.Module):
    """Image encoder fused with normalized clinical vector and missingness masks."""

    def __init__(
        self,
        clinical_features: int,
        num_grades: int = 5,
        pretrained: bool = True,
        backbone: str = "efficientnet_b0",
    ):
        super().__init__()
        if clinical_features < 1:
            raise ValueError("clinical_features must be positive")
        self.clinical_features = clinical_features
        self.backbone_name = backbone

        if backbone == "efficientnet_b0":
            weights = EfficientNet_B0_Weights.DEFAULT if pretrained else None
            bb = efficientnet_b0(weights=weights)
            self.image_encoder = bb.features
            self.image_pool = nn.AdaptiveAvgPool2d(1)
            in_features = 1280
        elif backbone.startswith("dinov2") or backbone.startswith("dino"):
            hub_name = backbone if "_" in backbone else "dinov2_vits14"
            try:
                bb = torch.hub.load("facebookresearch/dinov2", hub_name, pretrained=pretrained)
                self.image_encoder = bb
                self.image_pool = nn.Identity()
                in_features = getattr(bb, "embed_dim", 384)
            except Exception as e:
                raise RuntimeError(f"Failed to initialize DINO backbone '{hub_name}': {e}") from e
        else:
            raise ValueError(f"Unsupported backbone '{backbone}'. Choose 'efficientnet_b0' or 'dinov2_*'.")

        self.image_projection = nn.Sequential(
            nn.Flatten(),
            nn.Linear(in_features, 256),
            nn.ReLU(),
            nn.Dropout(0.25),
        )
        self.clinical_encoder = nn.Sequential(
            nn.Linear(clinical_features * 2, 64),
            nn.ReLU(),
            nn.Dropout(0.15),
            nn.Linear(64, 64),
            nn.ReLU(),
        )
        self.fusion = nn.Sequential(
            nn.Linear(320, 128),
            nn.ReLU(),
            nn.Dropout(0.25),
            nn.Linear(128, num_grades),
        )

    def forward(self, image: torch.Tensor, clinical: torch.Tensor) -> torch.Tensor:
        if not torch.jit.is_tracing():
            if clinical.ndim != 2 or clinical.shape[1] != self.clinical_features * 2:
                raise ValueError(
                    f"clinical input must have shape [batch, {self.clinical_features * 2}] "
                    f"containing [imputed_values, missingness_mask (1=missing, 0=observed)]"
                )
        if self.backbone_name == "efficientnet_b0":
            image_feats = self.image_pool(self.image_encoder(image))
        else:
            image_feats = self.image_encoder(image)

        image_features = self.image_projection(image_feats)
        clinical_features = self.clinical_encoder(clinical)
        return self.fusion(torch.cat((image_features, clinical_features), dim=1))
