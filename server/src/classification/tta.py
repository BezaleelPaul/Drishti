"""Test-time augmentation (TTA) ensemble for the DRDetect ordinal backend.

Fundus images are approximately rotation-symmetric, so horizontal/vertical
flips (and their composition, a 180-degree rotation) are label-preserving
transformations for diabetic-retinopathy grading.

Running the ordinal model on N views and averaging the continuous severity
scores gives two things the legacy single-pass could not:

1. **Ensemble noise reduction** - averaging N views lowers the variance of
   predictions near the referability threshold (score == 1.5), mimicking
   Google's published DR ensemble behaviour at a fraction of the cost.
2. **Honest uncertainty** - the *spread* (std) across views is a measured,
   model-derived disagreement signal. It widens the class-probability
   kernels (see src.classification.ordinal) so downstream confidence /
   ambiguity / OOD rules operate on real evidence instead of the old
   fabricated fixed-sigma Gaussian.

Configuration: ``DRISHTI_TTA_VIEWS`` env var - "1" restores single-pass
latency, "4" (default) runs the full flip ensemble.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np

DEFAULT_VIEW_COUNT = 4
SUPPORTED_VIEW_COUNTS = (1, DEFAULT_VIEW_COUNT)


@dataclass(frozen=True)
class TTAReport:
    """Immutable aggregation result across TTA views."""

    mean_score: float
    spread: float
    n_views: int
    scores: tuple[float, ...]


def resolve_view_count(requested: str | int | None) -> int:
    """Validates the configured TTA view count (defaults to the ensemble)."""
    if requested is None:
        return DEFAULT_VIEW_COUNT
    try:
        value = int(str(requested).strip())
    except ValueError:
        return DEFAULT_VIEW_COUNT
    return 1 if value <= 1 else DEFAULT_VIEW_COUNT


def build_views(input_tensor: np.ndarray, n_views: int) -> tuple[np.ndarray, ...]:
    """Builds the (immutable-input) view set: original, H, V, and 180-deg.

    Returns C-contiguous copies so onnxruntime accepts every view; the
    input tensor itself is never mutated.
    """
    tensor = np.ascontiguousarray(input_tensor)
    if tensor.ndim != 4:
        raise ValueError(f"Expected NCHW tensor with 4 dims, got shape {tensor.shape}.")
    if n_views == 1:
        return (tensor,)
    if n_views == DEFAULT_VIEW_COUNT:
        flipped_h = np.ascontiguousarray(np.flip(tensor, axis=3))
        flipped_v = np.ascontiguousarray(np.flip(tensor, axis=2))
        flipped_hv = np.ascontiguousarray(np.flip(flipped_v, axis=3))
        return (tensor, flipped_h, flipped_v, flipped_hv)
    raise ValueError(f"Unsupported TTA view count: {n_views}. Use one of {SUPPORTED_VIEW_COUNTS}.")


def aggregate_scores(scores: Sequence[float]) -> TTAReport:
    """Aggregates per-view ordinal scores into mean + spread statistics."""
    values = [float(s) for s in scores]
    if not values:
        raise ValueError("At least one TTA view score is required.")
    if any(not np.isfinite(v) for v in values):
        raise ValueError("TTA view scores must be finite.")
    if len(values) == 1:
        return TTAReport(mean_score=values[0], spread=0.0, n_views=1, scores=(values[0],))
    return TTAReport(
        mean_score=float(np.mean(values)),
        spread=float(np.std(values)),
        n_views=len(values),
        scores=tuple(values),
    )
