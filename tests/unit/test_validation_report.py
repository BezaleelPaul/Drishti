import json
from pathlib import Path

from validation.generate_report import (
    _classification_report,
    _quality_gate_report,
    leakage_report,
)

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def test_classification_report_refuses_unlabeled_fixtures():
    report = _classification_report(PROJECT_ROOT / "test_samples")

    assert report["status"] == "UNAVAILABLE"
    assert report["metrics"] is None


def test_leakage_report_detects_duplicate_fixture_copies():
    report = leakage_report(PROJECT_ROOT / "test_samples")

    assert report["images"] > 0
    assert report["duplicate_images"] > 0
    assert report["status"] == "ATTENTION_REQUIRED"


def test_quality_gate_report_flags_unresolved_real_fixture_acceptance():
    report = _quality_gate_report(PROJECT_ROOT / "test_samples")

    assert report["status"] == "ATTENTION_REQUIRED"
    assert report["good_fixture_acceptance_rate"] is not None
    assert report["good_fixture_acceptance_rate"] < 1.0


def test_generated_json_is_serializable(tmp_path):
    report = {
        "status": "UNAVAILABLE",
        "reason": "No labeled dataset supplied.",
    }
    output = tmp_path / "report.json"
    output.write_text(json.dumps(report), encoding="utf-8")

    assert json.loads(output.read_text(encoding="utf-8"))["status"] == "UNAVAILABLE"
