"""
Shared synthetic fundus-image generator for tests and offline evaluation scripts.

Lives in `src/` (not `tests/`) so production-side scripts such as
`evaluate_ab_test.py` can use it without depending on the test suite.
Deterministic for the default fundus path (no RNG); only the
`is_non_fundus` branch uses randomness.
"""

from __future__ import annotations

import cv2
import numpy as np


def create_synthetic_fundus_image(
    size: tuple[int, int] = (256, 256),
    blur_level: float = 0.0,
    brightness_shift: float = 0.0,
    is_non_fundus: bool = False,
    seed: int | None = None,
) -> np.ndarray:
    """Generates a synthetic circular retinal image for testing.

    - `blur_level` is a REAL blur radius scale: 0.0 = sharp, larger values
      apply a proportional Gaussian blur AFTER vessels are drawn.
    - `seed` makes the `is_non_fundus` branch reproducible (default path is
      already deterministic). Pass an int for evaluation reproducibility.
    """
    h, w = size
    if h <= 0 or w <= 0 or h > 4096 or w > 4096:
        raise ValueError(f"Invalid synthetic image size: {size!r}.")
    img = np.zeros((h, w, 3), dtype=np.uint8)

    if is_non_fundus:
        # Gray checkerboard / random blue noise
        rng = np.random.RandomState(seed) if seed is not None else np.random
        img[:, :, 2] = rng.randint(150, 255, (h, w)).astype(np.uint8)
        img[:, :, 0] = rng.randint(20, 50, (h, w)).astype(np.uint8)
        return img

    # Circular mask for fundus
    cy, cx = h // 2, w // 2
    r = int(min(h, w) * 0.42)
    y, x = np.ogrid[:h, :w]
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    circle_mask = dist <= r

    # Radial shading from macula to periphery for natural retinal contrast
    dist_norm = dist / (r + 1e-5)
    base_r = np.clip(210 - dist_norm * 50 + brightness_shift, 0, 255)
    base_g = np.clip(110 - dist_norm * 40 + brightness_shift * 0.6, 0, 255)
    base_b = np.clip(45 - dist_norm * 20 + brightness_shift * 0.3, 0, 255)

    img[circle_mask, 0] = base_r[circle_mask].astype(np.uint8)
    img[circle_mask, 1] = base_g[circle_mask].astype(np.uint8)
    img[circle_mask, 2] = base_b[circle_mask].astype(np.uint8)

    # Optic disc (nasal bright spot)
    od_cy, od_cx = cy, cx - int(r * 0.45)
    od_mask = (x - od_cx) ** 2 + (y - od_cy) ** 2 <= (r * 0.18) ** 2
    img[od_mask & circle_mask, 0] = 245
    img[od_mask & circle_mask, 1] = 220
    img[od_mask & circle_mask, 2] = 130

    # Add retinal vessel-like features (sharp high frequency lines)
    for angle_deg in [-30, 0, 30, 150, 180, 210]:
        rad = np.deg2rad(angle_deg)
        for d in range(10, int(r * 0.8)):
            vx = int(od_cx + d * np.cos(rad))
            vy = int(od_cy + d * np.sin(rad))
            if 0 <= vx < w and 0 <= vy < h and circle_mask[vy, vx]:
                img[max(0, vy - 1):min(h, vy + 2), max(0, vx - 1):min(w, vx + 2), 0] = 120
                img[max(0, vy - 1):min(h, vy + 2), max(0, vx - 1):min(w, vx + 2), 1] = 45
                img[max(0, vy - 1):min(h, vy + 2), max(0, vx - 1):min(w, vx + 2), 2] = 20

    if blur_level > 0.0:
        # Proportional Gaussian blur: blur_level=1.0 blurs with sigma ~2px
        # at 256px; scales with image size.
        sigma = max(0.5, float(blur_level) * min(h, w) / 256.0 * 2.0)
        k = max(3, int(sigma * 3) | 1)
        img = cv2.GaussianBlur(img, (k, k), sigmaX=sigma)

    return img
