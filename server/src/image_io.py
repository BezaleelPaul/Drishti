"""Shared image-loading contract for the Drishti-AI pipeline.

Every entry point (quality checker, classifier, Grad-CAM, router reassessment
loader, enhancer) funnels numpy input through :func:`to_rgb_uint8` so the same
pixels can never grade differently in different stages:

- float ``0-1`` scales to ``0-255`` (never truncates to black),
- non-finite pixels (NaN/inf) fail closed with ``ValueError``,
- integer input clips to ``[0, 255]`` (never wraps via ``astype``),
- 2-D grayscale expands to 3-channel, RGBA drops alpha,
- anything else (1-D, 5-channel, empty, >4K) raises ``ValueError``.

``RETINAL_BG_THRESHOLD`` is the single shared definition of "retinal vs.
background" darkness used by the checker FOV mask, the segmenter, the
enhancer border preservation, and the Grad-CAM saliency mask, so stage
denominators cannot disagree on dim border pixels.
"""

from __future__ import annotations

import numpy as np

#: Grayscale value above which a pixel counts as retinal tissue (not border).
RETINAL_BG_THRESHOLD: float = 15.0

#: Hard cap on decoded image dimensions (matches the API decompression guard).
MAX_IMAGE_DIM: int = 4096


def to_rgb_uint8(arr: np.ndarray) -> np.ndarray:
    """Convert arbitrary image array input to ``uint8`` ``(H, W, 3)`` RGB.

    Raises:
        ValueError: on non-finite pixels, empty/oversize images, or
            unsupported shapes/dtypes.
    """
    if not isinstance(arr, np.ndarray):
        raise TypeError(f"Expected numpy array, got {type(arr)}.")
    if arr.size == 0:
        raise ValueError("Empty image array.")
    if arr.ndim == 2:
        h, w = arr.shape
    elif arr.ndim == 3 and arr.shape[2] in (3, 4):
        h, w = arr.shape[0], arr.shape[1]
    else:
        raise ValueError(f"Unsupported image array shape: {arr.shape}.")
    if h <= 0 or w <= 0 or h > MAX_IMAGE_DIM or w > MAX_IMAGE_DIM:
        raise ValueError(f"Invalid image dimensions: {(h, w)}.")

    a = np.asarray(arr)
    if np.issubdtype(a.dtype, np.floating):
        if not np.all(np.isfinite(a)):
            raise ValueError("Image contains NaN or infinite pixel values.")
        mx = float(np.max(a))
        if mx <= 1.0:
            a = (np.clip(a, 0.0, 1.0) * 255.0).astype(np.uint8)
        elif float(np.mean(a > 1.0)) < 0.01:
            # A 0-1 image with a few hot-pixel outliers: saturate the
            # outliers to white instead of crushing the whole frame to black.
            a = (np.clip(a, 0.0, 1.0) * 255.0).astype(np.uint8)
        else:
            a = np.clip(a, 0.0, 255.0).astype(np.uint8)
    elif a.dtype == np.bool_:
        # Boolean masks: True means tissue -> full white, not near-black 1.
        a = np.where(a, 255, 0).astype(np.uint8)
    elif np.issubdtype(a.dtype, np.integer):
        if a.dtype == np.uint8:
            # Already canonical range: no clip/astype passes needed.
            # (Alias protection handled by the shares_memory guard below.)
            a = np.ascontiguousarray(a)
        else:
            # Integers are always finite. Clip in the ORIGINAL width first:
            # narrowing to int32 before clipping would wrap int64/uint64
            # values beyond +/-2**31 (e.g. 2**40 -> 0 instead of 255).
            a = np.clip(a, 0, 255).astype(np.uint8)
    else:
        raise ValueError(f"Unsupported image dtype: {a.dtype}.")

    if a.ndim == 2:
        a = np.stack([a] * 3, axis=-1)
    elif a.ndim == 3 and a.shape[2] == 4:
        a = a[:, :, :3].copy()
    res = np.ascontiguousarray(a, dtype=np.uint8)
    if np.shares_memory(res, arr):
        # Caller passed an already-canonical array: copy so downstream stages
        # can never mutate caller-owned pixels in place.
        res = res.copy()
    return res


def retinal_mask(gray: np.ndarray) -> np.ndarray:
    """Boolean retinal-tissue mask with the shared background threshold."""
    return np.asarray(gray) > RETINAL_BG_THRESHOLD


def rgb_to_gray(img_rgb: np.ndarray) -> np.ndarray:
    """ITU-R 601 luma grayscale (float32) shared by every stage.

    ``cv2.COLOR_RGB2GRAY`` uses these same weights (up to rounding), so masks
    built from :func:`rgb_to_gray` agree with OpenCV-derived masks and stage
    denominators cannot disagree on dim border pixels. Do NOT use
    ``mean(axis=2)``: it overweights green and shifts the mask.
    """
    a = np.asarray(img_rgb, dtype=np.float32)
    return 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
