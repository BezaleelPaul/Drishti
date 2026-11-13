"""Unit tests for the versioned ICDRS criteria engine (SYNTHETIC fixtures).

All fixtures are synthetic: lesion-candidate ids are fabricated strings and
counts are constructed inputs. These tests verify the ENGINE's determinism
and honesty semantics — they are NOT clinical validation.

Rule source: International Clinical Diabetic Retinopathy severity scale
(presence-based level definitions), restricted to the documented subset in
src.services.grading_policy.
"""

import pytest

from src.services.grading_policy import (
    FRAMEWORK,
    POLICY_ID,
    POLICY_VERSION,
    CriterionId,
    CriterionStatus,
    ImpliedGradeStatus,
    ReasonCode,
    evaluate_criteria,
)

MA = ("LE-0001", "LE-0002")
EX = ("LE-0003",)


def test_policy_identity_is_versioned():
    assert POLICY_ID == "icdrss-subset"
    assert POLICY_VERSION == "1.0"
    assert "International Clinical" in FRAMEWORK


def test_deterministic_same_inputs_same_outputs():
    a = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=EX, fovea_involved_ids=(), fovea_evaluable=False
    )
    b = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=EX, fovea_involved_ids=(), fovea_evaluable=False
    )
    assert a.criteria == b.criteria
    assert a.implied == b.implied


def test_ma_only_implies_level_1_with_open_upper_bound():
    res = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=(), fovea_involved_ids=(), fovea_evaluable=False
    )
    assert res.implied.implied_grade == 1
    assert res.implied.implied_status == ImpliedGradeStatus.ASSERTED_AT_LEAST
    assert res.implied.upper_bound_indeterminate is True
    ma_eval = next(c for c in res.criteria if c.criterion_id == CriterionId.MA_PRESENT.value)
    assert ma_eval.status == CriterionStatus.SATISFIED
    assert set(ma_eval.supporting_evidence_ids) == set(MA)


def test_ma_plus_exudates_implies_at_least_2():
    res = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=EX, fovea_involved_ids=(), fovea_evaluable=False
    )
    assert res.implied.implied_grade == 2
    assert res.implied.upper_bound_indeterminate is True
    ex_eval = next(c for c in res.criteria if c.criterion_id == CriterionId.EXUDATE_PRESENT.value)
    assert ex_eval.status == CriterionStatus.SATISFIED
    assert EX[0] in ex_eval.supporting_evidence_ids


def test_no_candidates_is_never_negative_evidence():
    res = evaluate_criteria(
        ma_evidence_ids=(), exudate_evidence_ids=(), fovea_involved_ids=(), fovea_evaluable=False
    )
    assert res.implied.implied_grade is None
    assert res.implied.implied_status == ImpliedGradeStatus.NO_CANDIDATES_DETECTED
    ma_eval = next(c for c in res.criteria if c.criterion_id == CriterionId.MA_PRESENT.value)
    # NOT 'not_met' — absence of detections is not proof of absence.
    assert ma_eval.status == CriterionStatus.INDETERMINATE
    assert ReasonCode.NO_CANDIDATES_DETECTED.value in ma_eval.reason_codes


def test_detector_failure_is_not_evaluated_and_blocks_implied_grade():
    res = evaluate_criteria(
        ma_evidence_ids=(),
        exudate_evidence_ids=(),
        fovea_involved_ids=(),
        ma_detector_failed=True,
        fovea_evaluable=False,
    )
    ma_eval = next(c for c in res.criteria if c.criterion_id == CriterionId.MA_PRESENT.value)
    assert ma_eval.status == CriterionStatus.NOT_EVALUATED
    assert ReasonCode.DETECTOR_FAILED.value in ma_eval.reason_codes
    assert res.implied.implied_status == ImpliedGradeStatus.INDETERMINATE
    assert res.implied.implied_grade is None


def test_unsupported_criteria_are_explicit_not_evaluated():
    res = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=EX, fovea_involved_ids=(), fovea_evaluable=False
    )
    for unsupported in (CriterionId.VENOUS_BEADING, CriterionId.NEOVASCULARIZATION):
        c = next(c for c in res.criteria if c.criterion_id == unsupported.value)
        assert c.status == CriterionStatus.NOT_EVALUATED
        assert ReasonCode.DETECTOR_NOT_IMPLEMENTED.value in c.reason_codes


def test_fovea_criterion_statuses():
    evaluable = evaluate_criteria(
        ma_evidence_ids=MA,
        exudate_evidence_ids=(),
        fovea_involved_ids=("LE-0001",),
        fovea_evaluable=True,
    )
    f = next(c for c in evaluable.criteria if c.criterion_id == CriterionId.FOVEA_INVOLVEMENT.value)
    assert f.status == CriterionStatus.SATISFIED
    assert "LE-0001" in f.supporting_evidence_ids
    assert ReasonCode.SPATIAL_RULE_APPLIED.value in f.reason_codes

    not_eval = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=(), fovea_involved_ids=(), fovea_evaluable=False
    )
    f2 = next(c for c in not_eval.criteria if c.criterion_id == CriterionId.FOVEA_INVOLVEMENT.value)
    assert f2.status == CriterionStatus.NOT_EVALUATED
    assert ReasonCode.LANDMARK_UNRELIABLE.value in f2.reason_codes


def test_explanation_keys_are_stable_and_linked_to_criteria():
    res = evaluate_criteria(
        ma_evidence_ids=MA, exudate_evidence_ids=EX, fovea_involved_ids=(), fovea_evaluable=False
    )
    for c in res.criteria:
        assert c.explanation_key.startswith("criterion_")
        assert c.explanation_key  # never empty: UI keys off these ids


def test_every_criterion_has_documented_description():
    from src.services.grading_policy import CRITERION_DESCRIPTIONS

    for cid in CriterionId:
        assert cid.value in CRITERION_DESCRIPTIONS


@pytest.mark.parametrize(
    "ma_ids, ex_ids, expected_grade, expected_status",
    [
        (MA, (), 1, ImpliedGradeStatus.ASSERTED_AT_LEAST),
        (MA, EX, 2, ImpliedGradeStatus.ASSERTED_AT_LEAST),
        ((), (), None, ImpliedGradeStatus.NO_CANDIDATES_DETECTED),
    ],
)
def test_implied_grade_matrix(ma_ids, ex_ids, expected_grade, expected_status):
    res = evaluate_criteria(
        ma_evidence_ids=ma_ids,
        exudate_evidence_ids=ex_ids,
        fovea_involved_ids=(),
        fovea_evaluable=False,
    )
    assert res.implied.implied_grade == expected_grade
    assert res.implied.implied_status == expected_status
