"""Tests for the mBRSET multimodal DR research pipeline (§3, §5, §6)."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
import torch
from PIL import Image
from sklearn.preprocessing import StandardScaler

from research.mbrset_multimodal.model import (
    ClinicalOnlyDRClassifier,
    ImageOnlyDRClassifier,
    RetinalClinicalFusion,
    TemperatureScaler,
)
from research.mbrset_multimodal.train import (
    ClinicalPreprocessor,
    FusionDataset,
    _split_by_patient,
    compute_ece_and_brier,
    compute_metrics,
    compute_paired_patient_bootstrap_delta,
    compute_patient_bootstrap_ci,
    preprocess_clinical_vector,
)


class TestModelArchitectures:
    def test_image_only_classifier_forward(self):
        model = ImageOnlyDRClassifier(num_grades=5, pretrained=False)
        model.eval()
        dummy_img = torch.randn(2, 3, 224, 224)
        out = model(dummy_img)
        assert out.shape == (2, 5)

    def test_clinical_only_classifier_forward_and_validation(self):
        model = ClinicalOnlyDRClassifier(clinical_features=3, num_grades=5)
        model.eval()

        # Valid input: [batch, clinical_features * 2] (3 values + 3 missingness masks)
        dummy_clinical = torch.randn(4, 6)
        out = model(dummy_clinical)
        assert out.shape == (4, 5)

        # Invalid shape: odd dimension or mismatched features must fail closed
        with pytest.raises(ValueError, match="clinical input must have shape"):
            model(torch.randn(4, 5))

        with pytest.raises(ValueError, match="clinical_features must be positive"):
            ClinicalOnlyDRClassifier(clinical_features=0)

    def test_retinal_clinical_fusion_forward_and_validation(self):
        model = RetinalClinicalFusion(clinical_features=4, num_grades=5, pretrained=False)
        model.eval()

        dummy_img = torch.randn(2, 3, 224, 224)
        dummy_clinical = torch.randn(2, 8)  # 4 values + 4 missingness masks
        out = model(dummy_img, dummy_clinical)
        assert out.shape == (2, 5)

        # Mismatched clinical dimensions must fail closed
        with pytest.raises(ValueError, match="clinical input must have shape"):
            model(dummy_img, torch.randn(2, 6))


class TestPreprocessingAndMissingnessConvention:
    def test_missingness_mask_convention(self, tmp_path: Path):
        """Test §3a: mask = 1 means missing; mask = 0 means observed."""
        img_dir = tmp_path / "images"
        img_dir.mkdir()
        img_file = img_dir / "eye1.png"
        Image.fromarray(np.zeros((64, 64, 3), dtype=np.uint8)).save(img_file)

        df = pd.DataFrame({
            "image_path": ["eye1.png"],
            "patient_id": ["p1"],
            "dr_grade": [2],
            "age": [55.0],
            "hba1c": [np.nan],  # missing
            "sbp": [130.0],
        })

        clinical_cols = ["age", "hba1c", "sbp"]
        scaler = StandardScaler()
        # Train split without NaNs for scaler fitting
        train_clinical = pd.DataFrame({
            "age": [50.0, 60.0],
            "hba1c": [7.0, 8.0],
            "sbp": [120.0, 140.0],
        })
        scaler.fit(train_clinical)

        dataset = FusionDataset(
            frame=df,
            image_root=img_dir,
            image_column="image_path",
            clinical_columns=clinical_cols,
            grade_column="dr_grade",
            scaler=scaler,
            image_size=64,
        )

        img_tensor, clinical_tensor, grade_tensor = dataset[0]

        assert img_tensor.shape == (3, 64, 64)
        assert grade_tensor.item() == 2
        assert clinical_tensor.shape == (6,)  # 3 imputed/scaled + 3 masks

        # First 3 elements are imputed/scaled values
        # Next 3 elements are missingness masks: mask=1 is missing, mask=0 is observed
        masks = clinical_tensor[3:].numpy()
        assert masks[0] == 0.0  # age was observed
        assert masks[1] == 1.0  # hba1c was missing (mask = 1 per §3a)
        assert masks[2] == 0.0  # sbp was observed

    def test_categorical_preprocessing_and_missingness(self):
        """Test categorical encoding and §3a missingness mask convention."""
        train_df = pd.DataFrame({
            "age": [45.0, 55.0, 65.0],
            "sex": ["F", "M", "F"],
            "insulin": ["no", "yes", "no"],
        })
        prep = ClinicalPreprocessor(
            numerical_columns=["age"],
            categorical_columns=["sex", "insulin"],
        )
        prep.fit(train_df)

        assert prep.category_modes["sex"] == "F"
        assert prep.category_modes["insulin"] == "no"
        assert prep.category_maps["sex"] == {"F": 0, "M": 1}
        assert prep.total_features == 3

        # Case 1: Fully observed observation
        row_obs = {"age": 55.0, "sex": "M", "insulin": "yes"}
        vec_obs = prep.transform_row(row_obs)
        assert vec_obs.shape == (6,)  # 3 features + 3 masks
        assert vec_obs[3] == 0.0  # age observed
        assert vec_obs[4] == 0.0  # sex observed
        assert vec_obs[5] == 0.0  # insulin observed
        assert vec_obs[1] == 1.0  # 'M' mapped to index 1

        # Case 2: Missing categorical feature (sex is NaN)
        row_miss = {"age": 45.0, "sex": np.nan, "insulin": "no"}
        vec_miss = prep.transform_row(row_miss)
        assert vec_miss[4] == 1.0  # sex missing (mask = 1 per §3a)
        assert vec_miss[1] == 0.0  # imputed with mode ('F' -> 0)

        # Case 3: Out-of-distribution / unseen category at inference
        row_ood = {"age": 50.0, "sex": "Other", "insulin": "no"}
        vec_ood = prep.transform_row(row_ood)
        assert vec_ood[4] == 1.0  # treated as missing / out-of-vocab per §3a

    def test_preprocess_clinical_vector_parity(self):
        """Test inference-time clinical preprocessing matches spec serialized from training (§3)."""
        train_df = pd.DataFrame({
            "age": [50.0, 60.0, 70.0],
            "sex": ["F", "M", "F"],
        })
        prep = ClinicalPreprocessor(
            numerical_columns=["age"],
            categorical_columns=["sex"],
        )
        prep.fit(train_df)
        spec = prep.to_dict()

        test_row = {"age": 60.0, "sex": "M"}
        vec_direct = prep.transform_row(test_row)
        vec_from_spec = preprocess_clinical_vector(test_row, spec)

        np.testing.assert_allclose(vec_direct, vec_from_spec, rtol=1e-5)


class TestPatientSplitAndLeakage:
    def test_split_by_patient_prevents_leakage(self):
        df = pd.DataFrame({
            "patient_id": [f"p{i}" for i in range(25) for _ in range(2)],
            "dr_grade": [i % 5 for i in range(50)],
        })
        train, val, test = _split_by_patient(df, "patient_id", seed=42)

        train_pts = set(train["patient_id"])
        val_pts = set(val["patient_id"])
        test_pts = set(test["patient_id"])

        assert len(train_pts & val_pts) == 0
        assert len(train_pts & test_pts) == 0
        assert len(val_pts & test_pts) == 0


class TestEvaluationUnitAndBootstrap:
    def test_metrics_and_bootstrap_ci(self):
        y_true = np.array([0, 1, 2, 3, 4, 0, 1, 2, 3, 4])
        y_pred = np.array([0, 1, 2, 2, 4, 0, 0, 2, 3, 4])

        metrics = compute_metrics(y_true, y_pred)
        assert "macro_f1" in metrics
        assert "quadratic_weighted_kappa" in metrics
        assert "referable_dr_sensitivity" in metrics
        assert "referable_dr_specificity" in metrics
        assert "confusion_matrix" in metrics
        assert len(metrics["confusion_matrix"]) == 5

        patient_df = pd.DataFrame({
            "patient_id": [f"p{i}" for i in range(10)],
            "y_true": y_true,
            "y_pred": y_pred,
        })
        ci = compute_patient_bootstrap_ci(patient_df, n_bootstrap=50, seed=42)
        assert "macro_f1_95ci" in ci
        assert "qwk_95ci" in ci
        assert ci["macro_f1_95ci"][0] <= ci["macro_f1_95ci"][1]

    def test_paired_patient_bootstrap_delta(self):
        patient_df_a = pd.DataFrame({
            "patient_id": [f"p{i}" for i in range(10)],
            "y_true": [0, 1, 2, 3, 4, 0, 1, 2, 3, 4],
            "y_pred": [0, 1, 2, 3, 4, 0, 1, 2, 3, 4],
        })
        patient_df_b = pd.DataFrame({
            "patient_id": [f"p{i}" for i in range(10)],
            "y_pred": [0, 1, 2, 2, 4, 0, 0, 2, 3, 4],
        })

        delta_res = compute_paired_patient_bootstrap_delta(patient_df_a, patient_df_b, n_bootstrap=50, seed=42)
        assert "delta_macro_f1_mean" in delta_res
        assert "delta_macro_f1_95ci" in delta_res
        assert delta_res["delta_macro_f1_mean"] >= 0.0


class TestTrainingExecution:
    @pytest.fixture
    def mock_training_dir(self, tmp_path: Path):
        img_dir = tmp_path / "images"
        img_dir.mkdir()
        rows = []
        for p_idx in range(12):
            for i_idx in range(2):
                img_name = f"p{p_idx}_img{i_idx}.png"
                Image.fromarray(np.zeros((32, 32, 3), dtype=np.uint8)).save(img_dir / img_name)
                rows.append({
                    "image_id": img_name,
                    "subject_id": f"sub_{p_idx}",
                    "dr_label": p_idx % 5,
                    "feat_age": 40 + p_idx,
                    "feat_bmi": 22.0 + (np.nan if (p_idx + i_idx) % 3 == 0 else (p_idx * 0.5)),
                })
        meta_csv = tmp_path / "metadata.csv"
        pd.DataFrame(rows).to_csv(meta_csv, index=False)

        cfg_file = tmp_path / "config.json"
        cfg_data = {
            "metadata_csv": str(meta_csv),
            "image_root": str(img_dir),
            "image_column": "image_id",
            "patient_column": "subject_id",
            "grade_column": "dr_label",
            "clinical_columns": ["feat_age", "feat_bmi"],
            "image_size": 32,
            "epochs": 1,
            "batch_size": 4,
            "seed": 42,
            "pretrained": False,
            "min_patients_train": 2,
            "min_patients_val": 2,
            "min_patients_test": 2,
            "check_dr_classes_all_splits": False,
            "n_bootstrap": 10,
            "output_dir": str(tmp_path / "artifacts"),
        }
        cfg_file.write_text(json.dumps(cfg_data), encoding="utf-8")
        return tmp_path, cfg_file

    def test_train_aborts_on_insufficient_patients_per_5a(self, mock_training_dir, monkeypatch):
        tmp_path, cfg_file = mock_training_dir
        # Reconfigure with default strict §5a threshold (train=10, val=30, test=30)
        strict_cfg = json.loads(cfg_file.read_text(encoding="utf-8"))
        strict_cfg["min_patients_val"] = 30
        strict_cfg_file = tmp_path / "strict_config.json"
        strict_cfg_file.write_text(json.dumps(strict_cfg), encoding="utf-8")

        monkeypatch.setattr("sys.argv", ["train.py", "--config", str(strict_cfg_file)])
        from research.mbrset_multimodal.train import main

        with pytest.raises(ValueError, match="Insufficient unique patients"):
            main()

    def test_train_clinical_only_and_fusion_success(self, mock_training_dir, monkeypatch):
        tmp_path, cfg_file = mock_training_dir
        from research.mbrset_multimodal.train import main

        # 1. Train clinical_only baseline
        monkeypatch.setattr("sys.argv", ["train.py", "--config", str(cfg_file), "--model", "clinical_only"])
        main()

        out_dir = tmp_path / "artifacts"
        assert (out_dir / "best_clinical_only.pt").is_file()
        assert (out_dir / "clinical_only.onnx").is_file()
        assert (out_dir / "temperature_scaler.pt").is_file()
        assert (out_dir / "preprocessing.json").is_file()
        assert (out_dir / "test_metrics.json").is_file()
        assert (out_dir / "model_card.md").is_file()
        card_content = (out_dir / "model_card.md").read_text(encoding="utf-8")
        assert "NOT A MEDICAL DEVICE" in card_content
        assert "Mitchell et al." in card_content
        assert "Calibration & Recalibration Analysis" in card_content

        prep = json.loads((out_dir / "preprocessing.json").read_text(encoding="utf-8"))
        assert prep["missingness_mask_convention"] == {"0": "observed", "1": "missing"}
        assert prep["clinical_columns"] == ["feat_age", "feat_bmi"]

        metrics = json.loads((out_dir / "test_metrics.json").read_text(encoding="utf-8"))
        assert metrics["model_type"] == "clinical_only"
        assert "evaluation_unit_image_level" in metrics
        assert "evaluation_unit_patient_level" in metrics
        assert "macro_f1_95ci" in metrics["evaluation_unit_patient_level"]
        assert "calibration" in metrics
        assert "calibrated_ece" in metrics["calibration"]

        # 2. Train fusion baseline
        monkeypatch.setattr("sys.argv", ["train.py", "--config", str(cfg_file), "--model", "fusion"])
        main()

        assert (out_dir / "best_fusion.pt").is_file()
        assert (out_dir / "fusion.onnx").is_file()


class TestCalibrationAndScaling:
    def test_temperature_scaler_reduces_nll_and_clamps(self):
        scaler = TemperatureScaler(init_temperature=1.0)
        val_logits = torch.tensor([[5.0, -5.0], [-5.0, 5.0]], requires_grad=False)
        val_labels = torch.tensor([0, 1])
        t = scaler.fit(val_logits, val_labels)
        assert t >= 0.05
        scaled = scaler(val_logits)
        assert scaled.shape == val_logits.shape

    def test_compute_ece_and_brier(self):
        y = np.array([0, 1, 2, 3, 4])
        perfect_probs = np.eye(5)
        res = compute_ece_and_brier(y, perfect_probs)
        assert res["ece"] == 0.0
        assert res["brier_score"] == 0.0

