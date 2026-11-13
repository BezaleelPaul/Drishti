"""CNN-vs-evidence reconciliation with deterministic, named reason codes.

Explains how the CNN grade relates to what the classical-CV criteria
subset can evidence, and decides when the result must be escalated to
review. The CNN grade is ALWAYS preserved as the prediction; the criteria
engine (src.services.grading_policy) never overwrites it, and this module
never silently selects either side.

Documented, deterministic rules (no invented confidence thresholds):

  MODEL_UNAVAILABLE      CNN grade missing/invalid -> review required.
  EVIDENCE_CONFLICT      criteria-implied level differs from the CNN grade
                         by >= 2 -> review required (material disagreement).
  EVIDENCE_ADJACENT      differs by exactly 1 -> advisory only (both are
                         plausible readings; the criterion evidence cannot
                         distinguish adjacent levels reliably).
  EVIDENCE_MATCH         same level -> consistent.
  EVIDENCE_NOT_ASSERTED  detector ran but found no candidates: NOT negative
                         evidence, no conflict can be derived.
  EVIDENCE_INCOMPLETE    a detector failed / criteria not evaluable -> no
                         conflict derivable; advisory only (never blocks
                         grading — mirrors the repo's advisory-failure rule).
  IMPLICATION_UPPER_BOUND_OPEN  implied grade carries an indeterminate
                         upper bound (beading/neovascularisation unseen).

Threshold-dependence: the >= 2 conflict window is a deterministic rule,
NOT a clinically validated threshold. Marked here as requiring validation
before any clinical use. Adjacent-level differences are deliberately not
escalated to avoid flooding the review queue on an unvalidated mapping.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from src.services.grading_policy import (
    POLICY_ID,
    POLICY_VERSION,
    ImpliedGradeStatus,
    ReasonCode,
)


class DisagreementStatus(str, Enum):
    MATCH = "match"
    ADJACENT = "adjacent"
    CONFLICT = "conflict"
    NOT_ASSERTED = "not_asserted"
    INCOMPLETE = "incomplete"
    MODEL_UNAVAILABLE = "model_unavailable"


@dataclass(frozen=True)
class DisagreementAssessment:
    status: DisagreementStatus
    reason_codes: tuple[str, ...]
    review_required: bool
    cnn_grade: int | None
    evidence_implied_grade: int | None
    explanation_key: str
    policy_id: str = POLICY_ID
    policy_version: str = POLICY_VERSION

    def summary(self) -> str:
        base = (
            f"CNN grade {self.cnn_grade if self.cnn_grade is not None else 'unavailable'} vs "
            f"evidence-implied {self.evidence_implied_grade if self.evidence_implied_grade is not None else 'none'}"
        )
        if self.status == DisagreementStatus.CONFLICT:
            return f"{base}: material disagreement — mandatory clinician review."
        if self.status == DisagreementStatus.ADJACENT:
            return f"{base}: adjacent-level difference; criteria mapping is unvalidated."
        if self.status == DisagreementStatus.MATCH:
            return f"{base}: consistent."
        if self.status == DisagreementStatus.MODEL_UNAVAILABLE:
            return f"{base}: model output missing — review required."
        if self.status == DisagreementStatus.INCOMPLETE:
            return f"{base}: detector evidence incomplete; no conflict derivable."
        return f"{base}: no candidates detected; absence is not negative evidence."


def reconcile(
    *,
    cnn_grade: int | None,
    implied_grade: int | None,
    implied_status: str,
    any_detector_failed: bool,
) -> DisagreementAssessment:
    """Deterministic CNN-vs-criteria reconciliation.

    Args:
        cnn_grade: the classifier's final grade (0-4) or None.
        implied_grade: the criteria engine's evidence-implied level or None.
        implied_status: one of ImpliedGradeStatus values.
        any_detector_failed: True when a required detector run failed.
    """
    codes: list[str] = []

    if cnn_grade is None or not isinstance(cnn_grade, int) or not 0 <= cnn_grade <= 4:
        codes.append("MODEL_UNAVAILABLE")
        return DisagreementAssessment(
            status=DisagreementStatus.MODEL_UNAVAILABLE,
            reason_codes=tuple(codes),
            review_required=True,
            cnn_grade=cnn_grade,
            evidence_implied_grade=implied_grade,
            explanation_key="disagreement_model_unavailable",
        )

    if implied_status == ImpliedGradeStatus.INDETERMINATE.value or any_detector_failed:
        codes.append(ReasonCode.DETECTOR_FAILED.value)
        codes.append("EVIDENCE_INCOMPLETE")
        return DisagreementAssessment(
            status=DisagreementStatus.INCOMPLETE,
            reason_codes=tuple(codes),
            review_required=False,
            cnn_grade=cnn_grade,
            evidence_implied_grade=None,
            explanation_key="disagreement_evidence_incomplete",
        )

    if implied_status != ImpliedGradeStatus.ASSERTED_AT_LEAST.value:
        codes.append("EVIDENCE_NOT_ASSERTED")
        codes.append(ReasonCode.NO_CANDIDATES_DETECTED.value)
        return DisagreementAssessment(
            status=DisagreementStatus.NOT_ASSERTED,
            reason_codes=tuple(codes),
            review_required=False,
            cnn_grade=cnn_grade,
            evidence_implied_grade=None,
            explanation_key="disagreement_not_asserted",
        )

    diff = abs(cnn_grade - implied_grade)
    codes.append(ReasonCode.CANDIDATES_PRESENT.value)
    if diff >= 2:
        codes.append("EVIDENCE_CONFLICT")
        return DisagreementAssessment(
            status=DisagreementStatus.CONFLICT,
            reason_codes=tuple(codes),
            review_required=True,
            cnn_grade=cnn_grade,
            evidence_implied_grade=implied_grade,
            explanation_key="disagreement_conflict",
        )
    if diff == 1:
        codes.append("EVIDENCE_ADJACENT")
        return DisagreementAssessment(
            status=DisagreementStatus.ADJACENT,
            reason_codes=tuple(codes),
            review_required=False,
            cnn_grade=cnn_grade,
            evidence_implied_grade=implied_grade,
            explanation_key="disagreement_adjacent",
        )
    codes.append("EVIDENCE_MATCH")
    return DisagreementAssessment(
        status=DisagreementStatus.MATCH,
        reason_codes=tuple(codes),
        review_required=False,
        cnn_grade=cnn_grade,
        evidence_implied_grade=implied_grade,
        explanation_key="disagreement_match",
    )
