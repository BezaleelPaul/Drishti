from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image

# Ensure external/fundus_image_toolbox is accessible
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_TOOLBOX_PATH = os.path.join(_PROJECT_ROOT, "external", "fundus_image_toolbox")
if os.path.exists(_TOOLBOX_PATH) and _TOOLBOX_PATH not in sys.path:
    sys.path.insert(0, _TOOLBOX_PATH)

try:
    import cv2
    HAS_OPENCV = True
except ImportError:
    HAS_OPENCV = False

try:
    from fundus_image_toolbox import crop as fit_circle_crop
    HAS_TOOLBOX_CROP = True
except Exception:  # noqa: BLE001 - optional toolbox crop uses OpenCV fallback
    HAS_TOOLBOX_CROP = False


class AdaptiveQualityEnhancer:
    """
    MathWorks SIH26038 Requirement #1:
    Adaptive enhancement for borderline fundus images:
    - Dynamic circular ROI extraction (via berenslab/fundus_image_toolbox EyeQ algorithm)
    - Dynamic Contrast-Limited Adaptive Histogram Equalization (CLAHE) in CIELAB space
    - Low-frequency background illumination bias correction
    - Bilateral edge-preserving denoising
    
    Provides an enhanced visual inspection layer for human operators
    while strictly preserving clinical audit compliance.
    """

    def __init__(self, clip_limit: float = 2.5, tile_grid_size: tuple = (8, 8)):
        if (
            not isinstance(tile_grid_size, (tuple, list))
            or len(tile_grid_size) != 2
            or not all(isinstance(v, (int, np.integer)) and int(v) > 0 for v in tile_grid_size)
        ):
            raise ValueError(
                f"tile_grid_size must be a tuple of two positive ints, got {tile_grid_size!r}"
            )
        self.clip_limit = clip_limit
        self.tile_grid_size = tuple(int(v) for v in tile_grid_size)

    def dynamic_circle_crop(
        self,
        img_rgb: np.ndarray,
        size: int = 512,
        return_mask: bool = False
    ) -> np.ndarray | tuple[np.ndarray, np.ndarray]:
        """
        Applies automated contour-based circular cropping.
        Removes dark boundary edges and camera frame margins dynamically.
        Accepts 2-D/RGBA/float input: normalized first through the shared
        loader contract (same as every other stage).
        """
        from src.image_io import to_rgb_uint8
        img_rgb = to_rgb_uint8(img_rgb)
        if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
            raise ValueError(
                f"dynamic_circle_crop expects an RGB image, got shape {img_rgb.shape}"
            )
        if HAS_TOOLBOX_CROP:
            try:
                cropped, mask, center, radius = fit_circle_crop(
                    img_rgb, size=size, return_all=True, to_numpy=True
                )
                if return_mask:
                    return cropped, mask
                return cropped
            except Exception as exc:  # noqa: BLE001 - optional crop uses OpenCV fallback
                import logging
                logging.getLogger(__name__).debug("Toolbox circle crop failed: %s", exc)

        # Robust OpenCV fallback contour crop
        if HAS_OPENCV:
            h, w, _ = img_rgb.shape
            gray = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
            from src.image_io import RETINAL_BG_THRESHOLD as _BG_TH
            _, thresh = cv2.threshold(gray, _BG_TH, 255, cv2.THRESH_BINARY)
            _cnt = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            contours = _cnt[0] if len(_cnt) == 2 else _cnt[1]
            if contours:
                c = max(contours, key=cv2.contourArea)
                (x, y), radius = cv2.minEnclosingCircle(c)
                center = (int(x), int(y))
                r = max(int(radius), 10)
                x1, y1 = max(0, center[0] - r), max(0, center[1] - r)
                x2, y2 = min(w, center[0] + r), min(h, center[1] + r)
                cropped = img_rgb[y1:y2, x1:x2]
                if cropped.size == 0:
                    cropped = img_rgb
                # Pad to square before resize to avoid aspect distortion
                ch, cw = cropped.shape[:2]
                side = max(ch, cw)
                pad_h, pad_w = side - ch, side - cw
                cropped = np.pad(
                    cropped,
                    ((pad_h // 2, pad_h - pad_h // 2), (pad_w // 2, pad_w - pad_w // 2), (0, 0)),
                    mode="constant",
                    constant_values=0,
                )
                cropped_resized = cv2.resize(cropped, (size, size))
                mask = np.zeros((size, size), dtype=np.uint8)
                cv2.circle(mask, (size // 2, size // 2), size // 2, 255, -1)
                if return_mask:
                    return cropped_resized, mask
                return cropped_resized

        resized = np.array(Image.fromarray(img_rgb).resize((size, size)))
        if return_mask:
            return resized, np.ones((size, size), dtype=np.uint8) * 255
        return resized

    def enhance_borderline_image(self, img_rgb: np.ndarray) -> np.ndarray:
        """
        Applies adaptive CLAHE, illumination normalization, and denoising.
        Preserves color fidelity by processing strictly in LAB / Luminance color space.
        Accepts 2-D/RGBA/float input: normalized first through the shared
        loader contract (same as every other stage).
        """
        from src.image_io import to_rgb_uint8
        img_rgb = to_rgb_uint8(img_rgb)
        if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
            raise ValueError(
                f"enhance_borderline_image expects an RGB image, got shape {img_rgb.shape}"
            )
        h, w, _ = img_rgb.shape
        if not HAS_OPENCV:
            # Fallback contrast stretch
            p2, p98 = np.percentile(img_rgb, (2, 98))
            return np.clip((img_rgb - p2) / (p98 - p2 + 1e-5) * 255.0, 0, 255).astype(np.uint8)

        # 1. Convert to LAB color space to decouple luminance from chrominance
        lab = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2LAB)
        l_chan, a_chan, b_chan = cv2.split(lab)

        # 2. Dynamic parameter adaptation based on local luminance standard deviation
        local_contrast = float(np.std(l_chan))
        adapted_clip = self.clip_limit
        if local_contrast < 12.0:
            adapted_clip = min(self.clip_limit * 1.4, 4.0)  # Boost low contrast
        elif local_contrast > 25.0:
            adapted_clip = max(self.clip_limit * 0.8, 1.5)  # Moderate high contrast

        # 3. Illumination Normalization (estimate spatial low-frequency background bias)
        # Bound kernel to [3, 51], odd, and <= min(h, w) to avoid cv2.error.
        kernel_size = int(min(h, w) * 0.15) | 1  # |1 guarantees odd; no even-fixup needed
        kernel_size = max(3, min(51, kernel_size))
        min_dim = min(h, w)
        if kernel_size > min_dim:
            kernel_size = min_dim if (min_dim % 2 == 1) else max(3, min_dim - 1)
        if min_dim < 3:
            # Too tiny to blur: skip illumination estimation, use the channel as-is.
            background = l_chan
        else:
            background = cv2.GaussianBlur(l_chan, (kernel_size, kernel_size), 0)
        # Mask-aware mean: ignore black non-retinal background in illumination estimate.
        gray_for_mask = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
        from src.image_io import retinal_mask as _retinal_mask
        retinal_px = l_chan[_retinal_mask(gray_for_mask)]
        mean_l = float(np.mean(retinal_px)) if retinal_px.size > 0 else float(np.mean(l_chan))
        norm_l = np.clip((l_chan.astype(np.float32) / (background.astype(np.float32) + 1e-5)) * mean_l, 0, 255).astype(np.uint8)

        # 4. Adaptive CLAHE on normalized luminance channel. Tile grid is
        # clamped to the image size: the default (8,8) tiles throw cv2.error
        # on tiny images (e.g. 4x4).
        tile_x = max(1, min(self.tile_grid_size[0], h // 8 or 1))
        tile_y = max(1, min(self.tile_grid_size[1], w // 8 or 1))
        clahe = cv2.createCLAHE(clipLimit=adapted_clip, tileGridSize=(tile_x, tile_y))
        enhanced_l = clahe.apply(norm_l)

        # 5. Bilateral Denoising (smooths sensor noise while preserving sharp vessel borders)
        denoised_l = cv2.bilateralFilter(enhanced_l, d=5, sigmaColor=35, sigmaSpace=35)

        # 6. Recombine channels and convert back to RGB
        enhanced_lab = cv2.merge([denoised_l, a_chan, b_chan])
        enhanced_rgb = cv2.cvtColor(enhanced_lab, cv2.COLOR_LAB2RGB)

        # Preserve black non-retinal background boundary
        gray_orig = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
        mask = _retinal_mask(gray_orig)
        result = np.zeros_like(img_rgb)
        result[mask] = enhanced_rgb[mask]

        return result
