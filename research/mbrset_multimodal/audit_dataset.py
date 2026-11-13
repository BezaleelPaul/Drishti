"""Audit a local mBRSET release without exposing patient-level data."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd


def audit(root: Path, metadata: Path) -> dict:
    if not root.exists() or not metadata.is_file():
        raise FileNotFoundError("Dataset root and metadata CSV must exist locally.")
    frame = pd.read_csv(metadata)
    image_files = {p.name: p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg", ".png"}}
    columns = list(frame.columns)
    lower = {c: c.lower().replace("-", "_").replace(" ", "_") for c in columns}

    def candidates(tokens: tuple[str, ...]) -> list[str]:
        return [c for c, normalized in lower.items() if any(t in normalized for t in tokens)]

    patient_cols = candidates(("patient", "subject", "participant", "person", "id"))
    image_cols = candidates(("image", "file", "path", "filename", "photo"))
    dr_grade_cols = candidates(("dr_grade", "retinopathy", "diabetic_retinopathy", "severity", "grade"))
    clinical_cols = candidates(("age", "sex", "gender", "diabetes", "insulin", "hypertension", "hba1c", "glucose", "bmi"))

    report = {
        "metadata_file": metadata.name,
        "rows": int(len(frame)),
        "columns": columns,
        "image_file_count": len(image_files),
        "candidate_patient_id_columns": patient_cols,
        "candidate_image_columns": image_cols,
        "candidate_dr_grade_columns": dr_grade_cols,
        "candidate_clinical_columns": clinical_cols,
        "missing_values_by_column": {str(c): int(frame[c].isna().sum()) for c in columns},
        "duplicate_rows": int(frame.duplicated().sum()),
    }

    # Verify actual image-to-metadata linkage (aggregate counts only)
    linkage_stats: dict[str, dict] = {}
    for img_col in image_cols:
        series = frame[img_col].dropna().astype(str)
        matched = 0
        missing = 0
        for val in series:
            name = Path(val).name
            if name in image_files or (root / val).is_file():
                matched += 1
            else:
                missing += 1
        linkage_stats[str(img_col)] = {
            "referenced_in_metadata": int(len(series)),
            "matched_on_disk": matched,
            "missing_from_disk": missing,
            "match_rate": round(matched / max(len(series), 1), 4),
        }
    report["image_linkage_verification"] = linkage_stats

    # Patient cohort aggregation (without patient IDs)
    patient_stats: dict[str, dict] = {}
    for pat_col in patient_cols:
        patient_series = frame[pat_col].dropna().astype(str)
        counts = patient_series.value_counts()
        multi_image = (counts > 1).sum()
        patient_stats[str(pat_col)] = {
            "unique_patients": int(len(counts)),
            "multi_image_patient_count": int(multi_image),
            "multi_image_patient_ratio": round(float(multi_image) / max(len(counts), 1), 4),
            "min_images_per_patient": int(counts.min()) if len(counts) > 0 else 0,
            "max_images_per_patient": int(counts.max()) if len(counts) > 0 else 0,
            "mean_images_per_patient": round(float(counts.mean()), 2) if len(counts) > 0 else 0.0,
            "patient_grouped_split_feasible": bool(len(counts) >= 10),
        }
    report["patient_cohort_statistics"] = patient_stats

    # Aggregate label counts only for likely DR-grade fields; never emit patient rows.
    report["candidate_grade_distributions"] = {}
    for col in dr_grade_cols:
        counts = frame[col].astype("string").value_counts(dropna=False).head(20)
        report["candidate_grade_distributions"][str(col)] = {str(k): int(v) for k, v in counts.items()}
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=Path("mbrset_audit.json"))
    args = parser.parse_args()
    report = audit(args.root, args.metadata)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k not in {"columns", "missing_values_by_column", "candidate_grade_distributions"}}, indent=2))
    print(f"Full aggregate audit written to {args.out}")


if __name__ == "__main__":
    main()
