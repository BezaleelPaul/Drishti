"""Ordinal-regression decoding utilities for the DRDetect backend.

The DRDetect model outputs a single continuous severity score and the
5-grade decision is decoded against fixed thresholds. These helpers were
extracted from the single-pass path so that both the legacy (TTA off) and
the ensemble (TTA on) decoding stay numerically identical for identical
scores.

Key improvement over the legacy inline math:
``widened_sigma`` lets TTA's cross-view spread widen the severity
discretisation Gaussian, so the 5-class "probabilities" reported to the
confidence evaluator and OOD gate reflect *measured* disagreement between
augmented views instead of a fabricated fixed-width distribution.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np

# Legacy fixed sigma (centroid spread of the 5 gaussian class kernels).
BASE_SIGMA = 0.65

# sigma grows by K * (cross-view std of scores) when TTA is active.
TTA_SIGMA_SPREAD_K = 2.2

# Cross-view std contribution to the reported uncertainty signal.
SPREAD_UNCERTAINTY_K = 1.8


def decode_grade(score: float, thresholds: Sequence[float]) -> int:
    """Maps a continuous ordinal score to a grade in [0, 4] (strict >)."""
    grade = 0
    for th in thresholds:
        if score > th:
            grade += 1
    return int(min(4, max(0, grade)))


def normalize_score_to_ordinal_scale(score: float, thresholds: Sequence[float]) -> float:
    """Maps a continuous score from arbitrary thresholds into normalized [0, 4] scale.

    Preserves exact identity when thresholds are standard [0.5, 1.5, 2.5, 3.5].
    When using calibrated thresholds (e.g. [0.0035, 0.380, 2.150, 3.100]),
    maps each interval [t_{c-1}, t_c] linearly to [c - 0.5, c + 0.5] so the
    probability distribution peak matches the decoded grade.
    """
    if len(thresholds) != 4:
        return float(score)
    t0, t1, t2, t3 = (float(t) for t in thresholds)
    if (
        abs(t0 - 0.5) < 1e-4
        and abs(t1 - 1.5) < 1e-4
        and abs(t2 - 2.5) < 1e-4
        and abs(t3 - 3.5) < 1e-4
    ):
        return float(score)
    if score <= t0:
        denom = max(t0, 1e-6)
        return float(max(0.0, 0.5 * (score / denom)))
    elif score <= t1:
        denom = max(t1 - t0, 1e-6)
        return float(0.5 + (score - t0) / denom)
    elif score <= t2:
        denom = max(t2 - t1, 1e-6)
        return float(1.5 + (score - t1) / denom)
    elif score <= t3:
        denom = max(t3 - t2, 1e-6)
        return float(2.5 + (score - t2) / denom)
    else:
        span = max(t3 - t2, 0.5)
        return float(min(4.0, 3.5 + 0.5 * (score - t3) / span))


def boundary_uncertainty(score: float, thresholds: Sequence[float]) -> float:
    """Legacy score: proximity to the nearest grade decision boundary."""
    dist = min(abs(score - th) for th in thresholds)
    return float(np.exp(-dist))


def widened_sigma(spread: float) -> float:
    """Gaussian kernel width: fixed when view spread is zero, wider otherwise."""
    if not np.isfinite(spread) or spread < 0:
        raise ValueError("TTA spread must be a finite non-negative value.")
    return BASE_SIGMA + TTA_SIGMA_SPREAD_K * float(spread)


def probabilities_from_score(score: float, sigma: float = BASE_SIGMA) -> list[float]:
    """Discretises a continuous ordinal score into P(grade=c) for c in 0..4.

    Normalized gaussian kernels centred on the continuous score. Wider
    ``sigma`` (from TTA disagreement) yields a flatter, less confident
    distribution - which is exactly what downstream review triggers need.
    """
    if not np.isfinite(score):
        raise ValueError("Ordinar score must be finite.")
    if not np.isfinite(sigma) or sigma <= 0:
        raise ValueError("Sigma must be a positive finite value.")
    raw = [float(np.exp(-0.5 * ((c - score) / sigma) ** 2)) for c in range(5)]
    total = sum(raw)
    if total <= 0:  # pragma: no cover - exp overflow guard
        raise ValueError("Degenerate gaussian discretisation (zero mass).")
    return [p / total for p in raw]


def uncertainty_from_scores(
    score: float,
    thresholds: Sequence[float],
    spread: float = 0.0,
) -> float:
    """Combined uncertainty: boundary proximity OR cross-view disagreement.

    Single-pass behaviour (spread=0) degrades exactly to the legacy
    ``exp(-boundary_dist)`` signal.
    """
    if not np.isfinite(spread) or spread < 0:
        raise ValueError("TTA spread must be a finite non-negative value.")
    boundary_signal = boundary_uncertainty(score, thresholds)
    spread_signal = min(1.0, float(spread) * SPREAD_UNCERTAINTY_K)
    return float(max(boundary_signal, spread_signal))
