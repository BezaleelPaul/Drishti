from pathlib import Path

import pandas as pd

from research.mbrset_multimodal.audit_dataset import audit


def test_audit_reports_aggregate_fields_without_patient_rows(tmp_path: Path):
    root = tmp_path / "images"
    root.mkdir()
    (root / "eye_001.jpg").write_bytes(b"not-a-real-image")
    metadata = tmp_path / "metadata.csv"
    pd.DataFrame({
        "patient_id": ["p1", "p2", "p1"],
        "image_path": ["eye_001.jpg", "missing.jpg", "eye_001.jpg"],
        "dr_grade": [0, 2, 0],
        "age": [51, None, 51],
        "hypertension": [True, False, True],
    }).to_csv(metadata, index=False)

    report = audit(root, metadata)

    assert report["rows"] == 3
    assert report["image_file_count"] == 1
    assert "patient_id" in report["candidate_patient_id_columns"]
    assert "image_path" in report["candidate_image_columns"]
    assert report["candidate_grade_distributions"]["dr_grade"] == {"0": 2, "2": 1}
    assert "patient_id" not in report  # no patient-level identifiers emitted

    # Verify actual image linkage
    linkage = report["image_linkage_verification"]["image_path"]
    assert linkage["referenced_in_metadata"] == 3
    assert linkage["matched_on_disk"] == 2
    assert linkage["missing_from_disk"] == 1

    # Verify patient cohort statistics
    patient_stats = report["patient_cohort_statistics"]["patient_id"]
    assert patient_stats["unique_patients"] == 2
    assert patient_stats["multi_image_patient_count"] == 1
    assert patient_stats["max_images_per_patient"] == 2
    assert patient_stats["min_images_per_patient"] == 1
