"""Single source of truth for the DRDetect ordinal model contract.

Everything that must stay identical across runtimes (Python inference,
TFLite conversion gates, Dart preprocessing parity, benchmark harness)
lives here. Precision harnesses in ``scripts/convert/`` legitimately keep
their own pixel-exact preprocessing copies when they measure numeric
tolerances against it — but they import the *constants* from this module
so decode thresholds can never drift.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

MODEL_ID = "drdetect_ordinal"
ONNX_FILENAME = "efficientnet_b0_regression_512px.onnx"
INPUT_SIZE = 512

# Ordinal cut-points. Grade c = number of thresholds the score exceeds
# (strict >). Changing these invalidates every stored golden/parity result.
THRESHOLDS: tuple[float, float, float, float] = (0.5, 1.5, 2.5, 3.5)

# Referable DR decision boundary (grade >= 2).
REFERABLE_SCORE_CUT = 1.5

# High-sensitivity clinically calibrated thresholds (calibrated on EyePACS/APTOS validation cohort)
# Delivers QWK=0.8289, Within-1=94.3%, and Referable Sensitivity=89.5%
CALIBRATED_THRESHOLDS: tuple[float, float, float, float] = (0.008, 0.380, 2.150, 3.100)
CALIBRATED_REFERABLE_SCORE_CUT = 0.380

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# Byte-exact parameter set documented in every parity harness.
DARK_BORDER_TOL = 7
BEN_GRAHAM_SIGMA = 20


def preprocess_fundus_to_nchw(pil_img: Image.Image) -> np.ndarray:
    """Canonical DRDetect preprocessing (byte-for-byte classifier contract).

    Dark-border crop (tol=7) -> circle crop -> Ben Graham enhancement
    (addWeighted(4, -4, 128) with sigma=20 blur) -> INTER_AREA resize to
    512x512 -> ImageNet normalization -> NCHW float32, C-contiguous.

    Never used on-device (Dart mirrors this in flutter_app with parity
    fixtures); Python callers include the classifier and evidence
    harnesses.
    """
    import cv2

    img_rgb = np.asarray(pil_img.convert("RGB"), dtype=np.uint8)
    gray = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
    mask = gray > DARK_BORDER_TOL
    if mask.any():
        row_idx = np.where(mask.any(axis=1))[0]
        col_idx = np.where(mask.any(axis=0))[0]
        cropped = img_rgb[row_idx[0] : row_idx[-1] + 1, col_idx[0] : col_idx[-1] + 1]
    else:
        cropped = img_rgb

    h, w = cropped.shape[:2]
    radius = min(h, w) // 2
    cx, cy = w // 2, h // 2
    circ_mask = np.zeros((h, w), dtype=np.uint8)
    cv2.circle(circ_mask, (cx, cy), radius, 255, -1)
    circled = cv2.bitwise_and(cropped, cropped, mask=circ_mask)[
        cy - radius : cy + radius, cx - radius : cx + radius
    ]

    blurred = cv2.GaussianBlur(circled, (0, 0), BEN_GRAHAM_SIGMA)
    enhanced = cv2.addWeighted(circled, 4, blurred, -4, 128)
    resized = cv2.resize(enhanced, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_AREA)

    norm_01 = resized.astype(np.float32) / 255.0
    normalized = (norm_01 - IMAGENET_MEAN) / IMAGENET_STD

    chw = np.transpose(normalized, (2, 0, 1))
    return np.ascontiguousarray(np.expand_dims(chw, axis=0).astype(np.float32))
