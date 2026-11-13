"""Out-of-distribution (OOD) scoring for DR predictions.

Combines three cheap, model-agnostic signals into a single ``ood_score``
in ``[0, 1]``:

1. **Max-softmax deficit** (``1 - max(probs)``) — flat distributions are
   the classic symptom of inputs the classifier has never seen.
2. **Normalized predictive entropy** — ``-sum(p log p) / log(K)``.
3. **Input-statistic deviation** (optional) — distance of measured
   brightness/contrast from the fundus operating envelope. A confident
   prediction on pixels far outside the envelope is suspicious.

The detector is *advisory only*: it never blocks grading. Callers append
its flags to the confidence-flags list so reviewers see them.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass, field

NUM_CLASSES = 5

# Fundus operating envelope (grayscale 0-255) measured from the curated
# test_samples corpus. Pixels far outside this box are unlikely to be
# in-distribution fundus captures.
BRIGHTNESS_RANGE = (25.0, 200.0)
CONTRAST_MIN = 4.0

# Combined-score cut-off. Calibrated so a confident one-hot prediction scores
# 0.0 and a uniform distribution scores ~0.81 (0.45*0.8 deficit + 0.45*1.0
# entropy); both extremes verified in tests/unit/test_ood.py.
OOD_FLAG_THRESHOLD = 0.65


@dataclass
class OODResult:
    ood_score: float
    is_suspect: bool
    signals: list[str] = field(default_factory=list)


def _validate_probs(probabilities: Sequence[float]) -> list[float]:
    probs = [float(p) for p in probabilities]
    if len(probs) != NUM_CLASSES:
        raise ValueError(f"Expected {NUM_CLASSES} class probabilities, got {len(probs)}.")
    if any(not math.isfinite(p) or p < 0.0 for p in probs):
        raise ValueError("Probabilities must be finite and non-negative.")
    total = sum(probs)
    if total <= 0.0:
        raise ValueError("Probabilities sum to zero; not a valid distribution.")
    return [p / total for p in probs]


def ood_score(
    probabilities: Sequence[float],
    brightness: float | None = None,
    contrast: float | None = None,
) -> OODResult:
    """Scores how out-of-distribution a prediction looks.

    Returns an :class:`OODResult`. Raises :class:`ValueError` on malformed
    probability vectors (fail-closed: callers must not silently score).
    """
    probs = _validate_probs(probabilities)

    max_p = max(probs)
    deficit = 1.0 - max_p
    if NUM_CLASSES <= 1:
        entropy = 0.0  # Single class: no entropy
    else:
        entropy = -sum(p * math.log(p) for p in probs if p > 0.0) / math.log(NUM_CLASSES)

    signals: list[str] = []
    if deficit > 0.5:
        signals.append(f"low top-1 confidence ({max_p:.2f})")
    if entropy > 0.7:
        signals.append(f"high predictive entropy ({entropy:.2f})")

    stat_penalty = 0.0
    for name, val, lo, hi in (
        ("brightness", brightness, BRIGHTNESS_RANGE[0], BRIGHTNESS_RANGE[1]),
        ("contrast", contrast, CONTRAST_MIN, None),
    ):
        if val is None:
            continue
        v = float(val)
        if not math.isfinite(v):
            raise ValueError(f"{name} must be finite, got {val!r}.")
        if v < lo or (hi is not None and v > hi):
            stat_penalty += 0.25
            signals.append(f"{name} outside fundus envelope ({v:.1f})")

    combined = 0.45 * deficit + 0.45 * entropy + stat_penalty
    combined = min(1.0, max(0.0, combined))
    return OODResult(
        ood_score=round(combined, 4),
        is_suspect=combined >= OOD_FLAG_THRESHOLD,
        signals=signals,
    )
