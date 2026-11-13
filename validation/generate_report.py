"""Generate an honest baseline validation report.

Usage:
    python validation/generate_report.py
    python validation/generate_report.py --data /path/to/grade_0..grade_4

The default repository fixtures contain no clinical labels. In that mode this
command reports operational quality-gate behavior and explicitly marks
classification metrics as unavailable. It never treats synthetic labels as
clinical accuracy evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parents[1]
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp"}


def _image_files(root: Path) -> list[Path]:
    return sorted(
        path for path in root.rglob("*") if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _wilson_interval(successes: int, total: int, z: float = 1.96) -> list[float] | None:
    if total <= 0:
        return None
    p = successes / total
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((p * (1 - p) + z * z / (4 * total)) / total) / denominator
    return [round(max(0.0, centre - margin), 4), round(min(1.0, centre + margin), 4)]


def leakage_report(root: Path) -> dict[str, Any]:
    files = _image_files(root)
    hashes: dict[str, list[str]] = {}
    for path in files:
        hashes.setdefault(_sha256(path), []).append(str(path.relative_to(root)))
    duplicates = [paths for paths in hashes.values() if len(paths) > 1]
    return {
        "images": len(files),
        "unique_content_hashes": len(hashes),
        "duplicate_groups": duplicates,
        "duplicate_images": sum(len(group) - 1 for group in duplicates),
        "status": "PASS" if not duplicates else "ATTENTION_REQUIRED",
        "note": (
            "Duplicate content was found, but no train/test split was supplied; "
            "this is not proof of leakage. Patient-level leakage requires patient IDs/metadata."
        ),
    }


def _quality_gate_report(root: Path) -> dict[str, Any]:
    from src.quality.checker import ImageQualityChecker

    checker = ImageQualityChecker()
    categories = {
        "good": root / "01_real_clinical_fundus",
        "bad": root / "02_quality_failures_and_edge_cases",
        "non_fundus": root / "03_adversarial_non_fundus",
        "scenarios": root / "04_section24_demo_scenarios",
    }
    rows: list[dict[str, Any]] = []
    for expected, directory in categories.items():
        if not directory.is_dir():
            continue
        for path in _image_files(directory):
            try:
                result = checker.assess_image(Image.open(path).convert("RGB"))
                observed = result.grade.value
                rows.append({"file": str(path.relative_to(root)), "expected_group": expected, "observed": observed})
            except Exception as exc:  # noqa: BLE001 - report each fixture failure
                rows.append({"file": str(path.relative_to(root)), "expected_group": expected, "error": str(exc)})

    bad_rows = [row for row in rows if row.get("expected_group") in {"bad", "non_fundus"}]
    good_rows = [row for row in rows if row.get("expected_group") == "good"]
    bad_rejected = sum(row.get("observed") == "BAD" for row in bad_rows)
    good_accepted = sum(row.get("observed") == "GOOD" for row in good_rows)
    good_acceptance_rate = round(good_accepted / len(good_rows), 4) if good_rows else None
    return {
        "fixture_rows": rows,
        "counts": dict(Counter(row.get("observed", "ERROR") for row in rows)),
        "bad_or_non_fundus_rejection_rate": (
            round(bad_rejected / len(bad_rows), 4) if bad_rows else None
        ),
        "good_fixture_acceptance_rate": good_acceptance_rate,
        "confidence_intervals": {
            "bad_or_non_fundus_rejection_rate_95ci": _wilson_interval(bad_rejected, len(bad_rows)),
            "good_fixture_acceptance_rate_95ci": _wilson_interval(good_accepted, len(good_rows)),
        },
        "status": "ATTENTION_REQUIRED" if good_acceptance_rate not in (None, 1.0) else "MEASURED_OPERATIONAL_FIXTURES",
        "note": "These are curated fixture behavior metrics, not clinical quality-gate sensitivity/specificity.",
    }


def _labeled_root(root: Path) -> bool:
    return all((root / f"grade_{grade}").is_dir() for grade in range(5))


def _classification_report(root: Path | None) -> dict[str, Any]:
    if root is None or not _labeled_root(root):
        return {
            "status": "UNAVAILABLE",
            "reason": "No labeled grade_0..grade_4 ImageFolder dataset was supplied.",
            "metrics": None,
        }

    from sklearn.metrics import (
        accuracy_score,
        cohen_kappa_score,
        confusion_matrix,
        f1_score,
        recall_score,
    )

    from src.classification.classifier import DRClassifier

    classifier = DRClassifier()
    if classifier.get_backend() == "simulated":
        return {
            "status": "UNAVAILABLE",
            "reason": "The classifier is running in simulated mode; no clinical metrics are reported.",
            "metrics": None,
            "model_backend": "simulated",
        }
    y_true: list[int] = []
    y_pred: list[int] = []
    confidence: list[float] = []
    for grade in range(5):
        for path in _image_files(root / f"grade_{grade}"):
            prediction = classifier.predict(Image.open(path).convert("RGB"))
            y_true.append(grade)
            y_pred.append(prediction.predicted_grade.value)
            confidence.append(prediction.confidence)

    matrix = confusion_matrix(y_true, y_pred, labels=list(range(5))).tolist()
    referable_true = [value >= 2 for value in y_true]
    referable_pred = [value >= 2 for value in y_pred]
    tp = sum(a and b for a, b in zip(referable_true, referable_pred))
    tn = sum(not a and not b for a, b in zip(referable_true, referable_pred))
    fp = sum(not a and b for a, b in zip(referable_true, referable_pred))
    fn = sum(a and not b for a, b in zip(referable_true, referable_pred))
    return {
        "status": "MEASURED_ON_CALLER_SUPPLIED_LABELS",
        "model_backend": classifier.get_backend(),
        "n": len(y_true),
        "metrics": {
            "accuracy": round(accuracy_score(y_true, y_pred), 4),
            "qwk": round(cohen_kappa_score(y_true, y_pred, weights="quadratic"), 4),
            "macro_f1": round(f1_score(y_true, y_pred, average="macro", zero_division=0), 4),
            "per_class_recall": [round(value, 4) for value in recall_score(y_true, y_pred, labels=list(range(5)), average=None, zero_division=0)],
            "referable_sensitivity": round(tp / (tp + fn), 4) if tp + fn else None,
            "referable_specificity": round(tn / (tn + fp), 4) if tn + fp else None,
            "referable_ppv": round(tp / (tp + fp), 4) if tp + fp else None,
            "referable_npv": round(tn / (tn + fn), 4) if tn + fn else None,
            "referable_fnr": round(fn / (tp + fn), 4) if tp + fn else None,
            "confusion_matrix": matrix,
            "mean_confidence": round(sum(confidence) / len(confidence), 4) if confidence else None,
        },
        "note": "This is not an untouched test result unless the caller supplies a locked test split.",
    }


def _markdown(report: dict[str, Any]) -> str:
    dataset = report["dataset"]
    classification = report["classification"]
    metrics = classification.get("metrics") or {}
    lines = [
        "# Drishti-AI Validation Report",
        "",
        "Generated by `python validation/generate_report.py`.",
        "This report distinguishes operational fixture checks from clinical model evidence.",
        "",
        "## Dataset",
        f"- Root: `{dataset['root']}`",
        f"- Images: {dataset['images']}",
        f"- Duplicate content images: {dataset['leakage']['duplicate_images']}",
        f"- Duplicate check status: **{dataset['leakage']['status']}**",
        "- Patient-level leakage: **UNAVAILABLE** without patient metadata",
        "",
        "## Classification",
        f"- Status: **{classification['status']}**",
    ]
    if metrics:
        for key in ("accuracy", "qwk", "macro_f1", "referable_sensitivity", "referable_specificity", "referable_fnr"):
            lines.append(f"- {key}: {metrics.get(key)}")
    else:
        lines.append(f"- Reason: {classification['reason']}")
    lines += [
        "",
        "## Quality Gate",
        f"- Status: **{report['quality_gate']['status']}**",
        f"- Bad/non-fundus rejection rate on curated fixtures: {report['quality_gate']['bad_or_non_fundus_rejection_rate']}",
        f"- Good fixture acceptance rate: {report['quality_gate']['good_fixture_acceptance_rate']}",
        "- Clinical sensitivity/specificity: **UNAVAILABLE** without expert-labeled quality data",
        "- Attention: real-fundus fixture acceptance is incomplete; collect quality labels before changing thresholds.",
        "",
        "## Calibration",
        "- ECE/Brier score: **UNAVAILABLE** unless a separate labeled calibration split is supplied",
        "",
        "## External and Expert Validation",
        "- External site/camera validation: **UNAVAILABLE**",
        "- Independent ophthalmologist adjudication: **UNAVAILABLE**",
        "",
        "## Interpretation",
        "Do not present synthetic or curated fixture results as clinical accuracy claims.",
        "Lock train/validation/calibration/test splits before tuning thresholds or reporting final metrics.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an honest Drishti-AI validation baseline report.")
    parser.add_argument("--data", type=Path, help="Labeled ImageFolder root with grade_0..grade_4 folders.")
    parser.add_argument("--out-dir", type=Path, default=PROJECT_ROOT / "results" / "validation")
    args = parser.parse_args()
    data_root = args.data.resolve() if args.data else None
    fixture_root = PROJECT_ROOT / "test_samples"
    leakage_root = data_root or fixture_root
    leakage = leakage_report(leakage_root)
    report = {
        "report_version": "baseline-001",
        "dataset": {"root": str(leakage_root), "images": leakage["images"], "leakage": leakage},
        "classification": _classification_report(data_root),
        "quality_gate": _quality_gate_report(fixture_root),
        "calibration": {"status": "UNAVAILABLE", "reason": "No separate labeled calibration split supplied."},
        "external_validation": {"status": "UNAVAILABLE"},
        "expert_validation": {"status": "UNAVAILABLE"},
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "validation_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    (args.out_dir / "VALIDATION_REPORT.md").write_text(_markdown(report), encoding="utf-8")
    print(_markdown(report))
    print(f"\nWrote {args.out_dir / 'VALIDATION_REPORT.md'}")
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(PROJECT_ROOT))
    raise SystemExit(main())
