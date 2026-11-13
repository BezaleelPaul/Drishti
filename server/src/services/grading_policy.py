"""Versioned grading-criteria engine for evidence-linked DR explanation.

Framework: International Clinical Diabetic Retinopathy (ICDRS) severity
scale — the framework named by the clinical project brief ("International
Clinical DR scale levels zero to four").

IMPLEMENTED SUBSET — READ THIS BEFORE TRUSTING AN OUTPUT
========================================================

The ICDRS grade levels are defined by lesion *presence*:

  Level 0: no microaneurysms (MAs).
  Level 1: microaneurysms only.
  Level 2: more than only MAs (e.g. exudates) — venous beading absent.
  Level 3: venous beading present.
  Level 4: neovascularisation and/or preretinal/ vitreous haemorrhage.

This module implements ONLY the criteria that the repository's classical-CV
detectors can actually evidence:

  * microaneurysm candidates (top-hat morphology, `structure_segmenter.py`)
  * exudate candidates (bright-lesion heuristic, same module)
  * foveal involvement (documented CSME proximity rule in the segmenter)

It explicitly does NOT implement:

  * venous beading, IRMA, neovascularisation, preretinal haemorrhage
    detection — no detector exists in this repository, and the available
    annotated data (IDRiD lesion masks on a few dozen images) cannot
    support training or validating one here.

Therefore every criteria output carries a documented upper-bound
indeterminacy: "exudates present" supports "at least level 2" but can never
rule out level 3/4, because those levels require evidence this system
cannot yet see. The evidence-implied grade is an *explanatory* artifact
bound to this policy version — it NEVER replaces or overwrites the CNN
grade (see src.services.disagreement), and "candidate" lesion detections
are not confirmed clinical lesions.

DETERMINISM: identical (evidence, policy-version) inputs always produce
identical outputs. All statuses and reason codes are stable string enums;
explanations are keyed (``explanation_key``), not free-form.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

# (str, Enum) not StrEnum: repo declares requires-python >=3.10 and StrEnum
# is 3.11+; serialization values are identical either way.

POLICY_ID = "icdrss-subset"
POLICY_VERSION = "1.0"
FRAMEWORK = "International Clinical Diabetic Retinopathy (ICDRS) severity scale"
SCHEMA_VERSION = "1.0"


class CriterionStatus(str, Enum):
    SATISFIED = "satisfied"
    NOT_MET = "not_met"
    INDETERMINATE = "indeterminate"
    NOT_EVALUATED = "not_evaluated"


class ImpliedGradeStatus(str, Enum):
    """What the evidence can honestly say about an ICDRS level.

    NOT_ASSERTED_NO_CANDIDATES: no candidates detected — this is NOT
    negative evidence (detector specificity is unvalidated); no grade is
    implied.
    ASSERTED_AT_LEAST: evidence supports grade >= implied value, upper
    levels cannot be excluded (missing beading/neovascularisation evidence).
    """

    ASSERTED_AT_LEAST = "asserted_at_least"
    NO_CANDIDATES_DETECTED = "no_candidates_detected"
    INDETERMINATE = "indeterminate"


class CriterionId(str, Enum):
    MA_PRESENT = "icdrss.ma_present"
    EXUDATE_PRESENT = "icdrss.exudate_present"
    FOVEA_INVOLVEMENT = "icdrss.fovea_involvement"
    VENOUS_BEADING = "icdrss.venous_beading"
    NEOVASCULARIZATION = "icdrss.neovascularization"


class ReasonCode(str, Enum):
    DETECTOR_RAN = "DETECTOR_RAN"
    DETECTOR_FAILED = "DETECTOR_FAILED"
    DETECTOR_NOT_IMPLEMENTED = "DETECTOR_NOT_IMPLEMENTED"
    CANDIDATES_PRESENT = "CANDIDATES_PRESENT"
    NO_CANDIDATES_DETECTED = "NO_CANDIDATES_DETECTED"
    LANDMARK_UNRELIABLE = "LANDMARK_UNRELIABLE"
    SPATIAL_RULE_APPLIED = "SPATIAL_RULE_APPLIED"
    CANDIDATES_ARE_NOT_CONFIRMED_LESIONS = "CANDIDATES_ARE_NOT_CONFIRMED_LESIONS"


EXPLANATION_KEYS = {
    CriterionId.MA_PRESENT.value: "criterion_ma_present",
    CriterionId.EXUDATE_PRESENT.value: "criterion_exudate_present",
    CriterionId.FOVEA_INVOLVEMENT.value: "criterion_fovea_involvement",
    CriterionId.VENOUS_BEADING.value: "criterion_unsupported",
    CriterionId.NEOVASCULARIZATION.value: "criterion_unsupported",
}

CRITERION_DESCRIPTIONS = {
    CriterionId.MA_PRESENT.value: (
        "Microaneurysms are the earliest ICDRS-visible lesion; their presence "
        "places an eye at level 1 or above (candidates from classical CV are "
        "not confirmed lesions)."
    ),
    CriterionId.EXUDATE_PRESENT.value: (
        "Hard exudates indicate 'more than microaneurysms only' (level 2+); "
        "upper levels cannot be excluded without venous-beading and "
        "neovascularisation evidence (not implemented)."
    ),
    CriterionId.FOVEA_INVOLVEMENT.value: (
        "Lesion candidates near the fovea relate to clinically significant "
        "macular edema risk (project rule: distance < 1.5x optic-disc radius)."
    ),
    CriterionId.VENOUS_BEADING.value: (
        "Venous beading defines ICDRS level 3. No detector exists in this "
        "repository; this criterion is explicitly NOT evaluated and its "
        "absence is never inferred."
    ),
    CriterionId.NEOVASCULARIZATION.value: (
        "Neovascularisation defines ICDRS level 4. No detector exists in this "
        "repository; this criterion is explicitly NOT evaluated and its "
        "absence is never inferred."
    ),
}


@dataclass(frozen=True)
class CriterionEvaluation:
    criterion_id: str
    status: CriterionStatus
    supporting_evidence_ids: tuple[str, ...] = ()
    contradicting_evidence_ids: tuple[str, ...] = ()
    reason_codes: tuple[str, ...] = ()
    explanation_key: str = ""


@dataclass(frozen=True)
class EvidenceImpliedGrade:
    """Honest statement of what the criteria imply about an ICDRS level."""

    implied_grade: int | None
    implied_status: ImpliedGradeStatus
    upper_bound_indeterminate: bool
    reason_codes: tuple[str, ...] = ()


@dataclass(frozen=True)
class GradingPolicyResult:
    policy_id: str
    policy_version: str
    framework: str
    criteria: tuple[CriterionEvaluation, ...]
    implied: EvidenceImpliedGrade
    notes: tuple[str, ...] = ()


def _ma_criterion(ma_evidence_ids: tuple[str, ...], detector_failed: bool) -> CriterionEvaluation:
    if detector_failed:
        return CriterionEvaluation(
            criterion_id=CriterionId.MA_PRESENT.value,
            status=CriterionStatus.NOT_EVALUATED,
            reason_codes=(ReasonCode.DETECTOR_FAILED.value,),
            explanation_key=EXPLANATION_KEYS[CriterionId.MA_PRESENT.value],
        )
    if ma_evidence_ids:
        return CriterionEvaluation(
            criterion_id=CriterionId.MA_PRESENT.value,
            status=CriterionStatus.SATISFIED,
            supporting_evidence_ids=ma_evidence_ids,
            reason_codes=(
                ReasonCode.DETECTOR_RAN.value,
                ReasonCode.CANDIDATES_PRESENT.value,
                ReasonCode.CANDIDATES_ARE_NOT_CONFIRMED_LESIONS.value,
            ),
            explanation_key=EXPLANATION_KEYS[CriterionId.MA_PRESENT.value],
        )
    # No candidates after a valid run: NOT negative evidence (the detector's
    # specificity is unvalidated). The criterion is indeterminate, not "not_met".
    return CriterionEvaluation(
        criterion_id=CriterionId.MA_PRESENT.value,
        status=CriterionStatus.INDETERMINATE,
        reason_codes=(
            ReasonCode.DETECTOR_RAN.value,
            ReasonCode.NO_CANDIDATES_DETECTED.value,
        ),
        explanation_key=EXPLANATION_KEYS[CriterionId.MA_PRESENT.value],
    )


def _exudate_criterion(
    ex_evidence_ids: tuple[str, ...], detector_failed: bool
) -> CriterionEvaluation:
    if detector_failed:
        return CriterionEvaluation(
            criterion_id=CriterionId.EXUDATE_PRESENT.value,
            status=CriterionStatus.NOT_EVALUATED,
            reason_codes=(ReasonCode.DETECTOR_FAILED.value,),
            explanation_key=EXPLANATION_KEYS[CriterionId.EXUDATE_PRESENT.value],
        )
    if ex_evidence_ids:
        return CriterionEvaluation(
            criterion_id=CriterionId.EXUDATE_PRESENT.value,
            status=CriterionStatus.SATISFIED,
            supporting_evidence_ids=ex_evidence_ids,
            reason_codes=(
                ReasonCode.DETECTOR_RAN.value,
                ReasonCode.CANDIDATES_PRESENT.value,
                ReasonCode.CANDIDATES_ARE_NOT_CONFIRMED_LESIONS.value,
            ),
            explanation_key=EXPLANATION_KEYS[CriterionId.EXUDATE_PRESENT.value],
        )
    return CriterionEvaluation(
        criterion_id=CriterionId.EXUDATE_PRESENT.value,
        status=CriterionStatus.INDETERMINATE,
        reason_codes=(
            ReasonCode.DETECTOR_RAN.value,
            ReasonCode.NO_CANDIDATES_DETECTED.value,
        ),
        explanation_key=EXPLANATION_KEYS[CriterionId.EXUDATE_PRESENT.value],
    )


def _fovea_criterion(
    fovea_involved_ids: tuple[str, ...],
    fovea_evaluable: bool,
) -> CriterionEvaluation:
    if not fovea_evaluable:
        return CriterionEvaluation(
            criterion_id=CriterionId.FOVEA_INVOLVEMENT.value,
            status=CriterionStatus.NOT_EVALUATED,
            reason_codes=(ReasonCode.LANDMARK_UNRELIABLE.value,),
            explanation_key=EXPLANATION_KEYS[CriterionId.FOVEA_INVOLVEMENT.value],
        )
    if fovea_involved_ids:
        return CriterionEvaluation(
            criterion_id=CriterionId.FOVEA_INVOLVEMENT.value,
            status=CriterionStatus.SATISFIED,
            supporting_evidence_ids=fovea_involved_ids,
            reason_codes=(ReasonCode.DETECTOR_RAN.value, ReasonCode.SPATIAL_RULE_APPLIED.value),
            explanation_key=EXPLANATION_KEYS[CriterionId.FOVEA_INVOLVEMENT.value],
        )
    # Distance rule evaluated; no candidate within the macular zone. Because
    # candidates themselves are unconfirmed, this stays indeterminate.
    return CriterionEvaluation(
        criterion_id=CriterionId.FOVEA_INVOLVEMENT.value,
        status=CriterionStatus.INDETERMINATE,
        reason_codes=(ReasonCode.DETECTOR_RAN.value, ReasonCode.SPATIAL_RULE_APPLIED.value),
        explanation_key=EXPLANATION_KEYS[CriterionId.FOVEA_INVOLVEMENT.value],
    )


def _unsupported_criterion(criterion_id: CriterionId) -> CriterionEvaluation:
    return CriterionEvaluation(
        criterion_id=criterion_id.value,
        status=CriterionStatus.NOT_EVALUATED,
        reason_codes=(ReasonCode.DETECTOR_NOT_IMPLEMENTED.value,),
        explanation_key=EXPLANATION_KEYS[criterion_id.value],
    )


def evaluate_criteria(
    *,
    ma_evidence_ids: tuple[str, ...],
    exudate_evidence_ids: tuple[str, ...],
    fovea_involved_ids: tuple[str, ...],
    ma_detector_failed: bool = False,
    exudate_detector_failed: bool = False,
    fovea_evaluable: bool = False,
) -> GradingPolicyResult:
    """Deterministically evaluates the versioned ICDRS criteria subset.

    All inputs are evidence ids / explicit flags produced by
    :mod:`src.services.evidence`. Never mutates inputs; identical inputs
    always yield identical outputs for the same POLICY_VERSION.
    """
    ma_eval = _ma_criterion(ma_evidence_ids, ma_detector_failed)
    ex_eval = _exudate_criterion(exudate_evidence_ids, exudate_detector_failed)
    fovea_eval = _fovea_criterion(fovea_involved_ids, fovea_evaluable)
    vb_eval = _unsupported_criterion(CriterionId.VENOUS_BEADING)
    nv_eval = _unsupported_criterion(CriterionId.NEOVASCULARIZATION)

    # ---- Evidence-implied grade (explanatory only, never a final grade) ----
    ma_positive = ma_eval.status == CriterionStatus.SATISFIED
    ex_positive = ex_eval.status == CriterionStatus.SATISFIED
    if ma_detector_failed or exudate_detector_failed:
        implied = EvidenceImpliedGrade(
            implied_grade=None,
            implied_status=ImpliedGradeStatus.INDETERMINATE,
            upper_bound_indeterminate=True,
            reason_codes=(ReasonCode.DETECTOR_FAILED.value,),
        )
    elif ma_positive and not ex_positive:
        implied = EvidenceImpliedGrade(
            implied_grade=1,
            implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST,
            upper_bound_indeterminate=True,
            reason_codes=(ReasonCode.CANDIDATES_PRESENT.value,),
        )
    elif ma_positive and ex_positive:
        implied = EvidenceImpliedGrade(
            implied_grade=2,
            implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST,
            upper_bound_indeterminate=True,
            reason_codes=(ReasonCode.CANDIDATES_PRESENT.value,),
        )
    else:
        implied = EvidenceImpliedGrade(
            implied_grade=None,
            implied_status=ImpliedGradeStatus.NO_CANDIDATES_DETECTED,
            upper_bound_indeterminate=True,
            reason_codes=(ReasonCode.NO_CANDIDATES_DETECTED.value,),
        )

    notes = (
        (
            "Upper ICDRS levels (3-4) cannot be excluded: venous beading and "
            "neovascularisation are not detectable by this policy version."
        ),
        "Candidate detections are heuristic segmenter outputs, not confirmed clinical lesions.",
    )
    return GradingPolicyResult(
        policy_id=POLICY_ID,
        policy_version=POLICY_VERSION,
        framework=FRAMEWORK,
        criteria=(ma_eval, ex_eval, fovea_eval, vb_eval, nv_eval),
        implied=implied,
        notes=notes,
    )
