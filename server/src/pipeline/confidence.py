from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from src.pipeline.schema import (
    ConfidenceAssessment,
    DRClassificationResult,
)


@dataclass
class ConfidenceConfig:
    """
    Configuration parameters for Confidence and Uncertainty evaluation per Section 7.
    """

    # Top-1 softmax probability threshold (default: 0.70).
    # Raised from 0.60 -> 0.70 on split-half validation over the full
    # 2,810-image shipped-backend run (tune half A(even) / confirm half
    # B(odd), results in docs/EVALUATION_RESULTS.md section 5): both halves
    # showed ~23% fewer missed referables in the released subset and higher
    # released accuracy, at ~8% lower release volume.
    min_confidence_threshold: float = 0.70

    # Margin between Top-1 and Top-2 probabilities (default: 0.15)
    min_ambiguity_margin: float = 0.15

    # Always flag high risk grades (Severe, Proliferative)
    always_flag_high_risk: bool = True


class ConfidenceEvaluator:
    """
    Implements Section 7: Confidence and Uncertainty Handling.
    Decides whether Model 2's prediction is reliable enough to finalize without
    human clinician intervention, or must be flagged for review.
    """

    def __init__(self, config: ConfidenceConfig = None):
        self.config = config or ConfidenceConfig()

    def evaluate(self, dr_result: DRClassificationResult) -> ConfidenceAssessment:
        """
        Evaluates confidence, ambiguity, and clinical risk rules.
        """
        flags: list[str] = []
        is_confident = True
        is_ambiguous = False
        is_high_risk = False
        requires_review = False

        # Rule 0: Input validation — NaN/inf or confidence != max(probs)
        try:
            probs = list(dr_result.probabilities) if dr_result.probabilities is not None else []
        except TypeError:
            probs = []
        conf_finite = (
            bool(np.isfinite(dr_result.confidence)) if dr_result.confidence is not None else False
        )
        margin_finite = (
            bool(np.isfinite(dr_result.top2_margin)) if dr_result.top2_margin is not None else False
        )
        probs_finite = len(probs) > 0 and all(
            isinstance(p, (int, float, np.floating, np.integer)) and bool(np.isfinite(p))
            for p in probs
        )
        if not conf_finite or not margin_finite or not probs_finite:
            is_confident = False
            requires_review = True
            flags.append(
                "Invalid confidence inputs (NaN/inf or missing values detected): mandatory human review"
            )
        else:
            try:
                max_prob = float(max(probs))
                if not np.isfinite(max_prob) or abs(float(dr_result.confidence) - max_prob) > 1e-6:
                    requires_review = True
                    is_confident = False
                    flags.append(
                        f"Confidence mismatch (confidence {dr_result.confidence:.4f} != max(probs) {max_prob:.4f}): mandatory human review"
                    )
            except Exception:  # noqa: BLE001 - invalid confidence must require review
                is_confident = False
                requires_review = True
                flags.append(
                    "Invalid confidence inputs (could not validate probabilities): mandatory human review"
                )

        # Rule 1: Low Softmax Confidence Check
        try:
            conf_val = float(dr_result.confidence)
            conf_valid = bool(np.isfinite(conf_val))
        except (TypeError, ValueError):
            conf_val = None
            conf_valid = False
        if conf_valid and conf_val < self.config.min_confidence_threshold:
            is_confident = False
            requires_review = True
            flags.append(
                f"Low confidence ({conf_val:.1%} < {self.config.min_confidence_threshold:.0%})"
            )

        # Rule 2: Class Ambiguity Check
        try:
            margin_val = float(dr_result.top2_margin)
            margin_valid = bool(np.isfinite(margin_val))
        except (TypeError, ValueError):
            margin_val = None
            margin_valid = False
        if margin_valid and margin_val < self.config.min_ambiguity_margin:
            is_ambiguous = True
            requires_review = True
            flags.append(
                f"Class ambiguity (Top-1/Top-2 margin {margin_val:.2f} < {self.config.min_ambiguity_margin:.2f})"
            )

        # Rule 3: High-Risk Grade Safety Override (Section 7)
        # "A high-risk grade is flagged even if the model is confident, because the
        # clinical cost of a missed Severe/Proliferative case is far higher than the
        # cost of one extra human review."
        if self.config.always_flag_high_risk and getattr(
            dr_result.predicted_grade, "is_high_risk", False
        ):
            is_high_risk = True
            requires_review = True
            flags.append(
                f"High-risk clinical grade ({dr_result.predicted_grade.label}): mandatory ophthalmologist over-read"
            )

        return ConfidenceAssessment(
            is_confident=is_confident,
            is_ambiguous=is_ambiguous,
            is_high_risk=is_high_risk,
            requires_human_review=requires_review,
            flags=flags,
        )
