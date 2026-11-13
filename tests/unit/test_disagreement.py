"""Unit tests for the deterministic CNN-vs-evidence reconciliation policy.

SYNTHETIC fixtures: grades and implied levels are constructed integers.
Verifies reason-code stability, escalation semantics, and that the CNN
grade is never mutated or replaced.
"""

import pytest

from src.services.disagreement import DisagreementStatus, reconcile
from src.services.grading_policy import POLICY_ID, POLICY_VERSION, ImpliedGradeStatus


def test_match_same_level():
    d = reconcile(
        cnn_grade=2,
        implied_grade=2,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.MATCH
    assert d.review_required is False
    assert "EVIDENCE_MATCH" in d.reason_codes
    assert d.cnn_grade == 2  # preserved, never mutated


def test_adjacent_levels_advisory_only():
    d = reconcile(
        cnn_grade=2,
        implied_grade=1,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.ADJACENT
    assert d.review_required is False
    assert "EVIDENCE_ADJACENT" in d.reason_codes


def test_conflict_two_levels_escalates_review():
    d = reconcile(
        cnn_grade=0,
        implied_grade=2,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.CONFLICT
    assert d.review_required is True
    assert "EVIDENCE_CONFLICT" in d.reason_codes
    # Both sides preserved: escalation never picks a winner.
    assert d.cnn_grade == 0
    assert d.evidence_implied_grade == 2


def test_higher_cnn_side_conflict_also_escalates():
    d = reconcile(
        cnn_grade=4,
        implied_grade=1,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.CONFLICT
    assert d.review_required is True


def test_not_asserted_is_not_negative_evidence():
    d = reconcile(
        cnn_grade=0,
        implied_grade=None,
        implied_status=ImpliedGradeStatus.NO_CANDIDATES_DETECTED.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.NOT_ASSERTED
    assert d.review_required is False
    assert "EVIDENCE_NOT_ASSERTED" in d.reason_codes


def test_detector_failure_yields_incomplete_never_blocks():
    d = reconcile(
        cnn_grade=2,
        implied_grade=None,
        implied_status=ImpliedGradeStatus.INDETERMINATE.value,
        any_detector_failed=True,
    )
    assert d.status == DisagreementStatus.INCOMPLETE
    assert d.review_required is False  # advisory path mirrors repo convention
    assert "EVIDENCE_INCOMPLETE" in d.reason_codes


@pytest.mark.parametrize("bad", [None, -1, 5, 2.5, "2"])
def test_model_unavailable_fail_closed(bad):
    d = reconcile(
        cnn_grade=bad,
        implied_grade=2,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.status == DisagreementStatus.MODEL_UNAVAILABLE
    assert d.review_required is True
    assert "MODEL_UNAVAILABLE" in d.reason_codes


def test_policy_provenance_carried():
    d = reconcile(
        cnn_grade=1,
        implied_grade=1,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    assert d.policy_id == POLICY_ID
    assert d.policy_version == POLICY_VERSION


def test_summary_never_empty_and_names_both_sides():
    d = reconcile(
        cnn_grade=0,
        implied_grade=2,
        implied_status=ImpliedGradeStatus.ASSERTED_AT_LEAST.value,
        any_detector_failed=False,
    )
    s = d.summary()
    assert "0" in s and "2" in s
