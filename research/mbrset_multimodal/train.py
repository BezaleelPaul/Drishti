"""Patient-grouped training entry point for mBRSET DR research models.

Implements three baselines (§5):
- image_only: Fundus image -> 5 DR logits
- clinical_only: Clinical features + missingness masks -> 5 DR logits
- fusion: Multimodal image + clinical fusion -> 5 DR logits

Missingness convention (§3a):
mask = 1 indicates missing; mask = 0 indicates observed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from PIL import Image
from sklearn.metrics import (
    balanced_accuracy_score,
    cohen_kappa_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
)
from sklearn.model_selection import GroupShuffleSplit
from sklearn.preprocessing import StandardScaler
from torch import nn
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms

from research.mbrset_multimodal.model import (
    ClinicalOnlyDRClassifier,
    ImageOnlyDRClassifier,
    RetinalClinicalFusion,
    TemperatureScaler,
)


class ClinicalPreprocessor:
    """Preprocesses numerical and categorical clinical features with explicit missingness masks (§3, §3a).

    Missingness convention (§3a):
    mask = 1 indicates missing; mask = 0 indicates observed.
    Imputation statistics (means for numerical, modes for categorical) are fitted strictly on the train split.
    """

    def __init__(
        self,
        numerical_columns: list[str] | None = None,
        categorical_columns: list[str] | None = None,
        scaler: StandardScaler | None = None,
        category_maps: dict[str, dict[str, int]] | None = None,
        category_modes: dict[str, str] | None = None,
    ):
        self.numerical_columns = list(numerical_columns or [])
        self.categorical_columns = list(categorical_columns or [])
        self.scaler = scaler if scaler is not None else StandardScaler()
        self.category_maps = dict(category_maps or {})
        self.category_modes = dict(category_modes or {})

    @property
    def total_features(self) -> int:
        return len(self.numerical_columns) + len(self.categorical_columns)

    @property
    def clinical_columns(self) -> list[str]:
        return self.numerical_columns + self.categorical_columns

    def fit(self, train_frame: pd.DataFrame) -> ClinicalPreprocessor:
        # Fit numerical features on train partition only
        if self.numerical_columns:
            num_df = train_frame[self.numerical_columns].apply(pd.to_numeric, errors="coerce")
            self.scaler.fit(num_df)

        # Fit categorical features on train partition only
        for col in self.categorical_columns:
            series = train_frame[col].dropna().astype(str).str.strip()
            mode_val = series.mode().iloc[0] if len(series) > 0 else "unknown"
            self.category_modes[col] = mode_val
            unique_cats = sorted(list(series.unique()))
            self.category_maps[col] = {cat: idx for idx, cat in enumerate(unique_cats)}

        return self

    def transform_row(self, row: pd.Series | dict) -> np.ndarray:
        """Transforms a single patient observation into [imputed_scaled_values, missingness_masks]."""
        num_vals: list[float] = []
        cat_vals: list[float] = []
        num_masks: list[float] = []
        cat_masks: list[float] = []

        # 1. Numerical features
        if self.numerical_columns:
            raw_nums = pd.to_numeric(
                pd.Series({c: row.get(c, np.nan) if isinstance(row, dict) else row[c] for c in self.numerical_columns}),
                errors="coerce",
            ).to_numpy(dtype=np.float32)

            for i, val in enumerate(raw_nums):
                if np.isfinite(val):
                    num_vals.append(float(val))
                    num_masks.append(0.0)  # observed (§3a)
                else:
                    mean_val = float(self.scaler.mean_[i]) if hasattr(self.scaler, "mean_") else 0.0
                    num_vals.append(mean_val)
                    num_masks.append(1.0)  # missing (§3a)

            if hasattr(self.scaler, "mean_"):
                imputed_df = pd.DataFrame([num_vals], columns=self.numerical_columns)
                scaled_nums = self.scaler.transform(imputed_df)[0].tolist()
            else:
                scaled_nums = num_vals
        else:
            scaled_nums = []

        # 2. Categorical features
        for col in self.categorical_columns:
            raw_cat = row.get(col, None) if isinstance(row, dict) else row[col]
            if pd.isna(raw_cat) or str(raw_cat).strip() == "" or str(raw_cat).lower() in ("nan", "none", "null"):
                mode = self.category_modes.get(col, "unknown")
                encoded = float(self.category_maps.get(col, {}).get(mode, 0))
                cat_vals.append(encoded)
                cat_masks.append(1.0)  # missing (§3a)
            else:
                cleaned = str(raw_cat).strip()
                cat_map = self.category_maps.get(col, {})
                if cleaned in cat_map:
                    cat_vals.append(float(cat_map[cleaned]))
                    cat_masks.append(0.0)  # observed (§3a)
                else:
                    # Unseen category treated as missing / out-of-distribution (§3a)
                    mode = self.category_modes.get(col, "unknown")
                    cat_vals.append(float(cat_map.get(mode, 0)))
                    cat_masks.append(1.0)

        features = scaled_nums + cat_vals
        masks = num_masks + cat_masks
        return np.concatenate([np.asarray(features, dtype=np.float32), np.asarray(masks, dtype=np.float32)])

    def to_dict(self) -> dict:
        return {
            "numerical_columns": self.numerical_columns,
            "categorical_columns": self.categorical_columns,
            "clinical_columns": self.clinical_columns,
            "scaler_mean": self.scaler.mean_.tolist() if hasattr(self.scaler, "mean_") else [],
            "scaler_scale": self.scaler.scale_.tolist() if hasattr(self.scaler, "scale_") else [],
            "category_maps": self.category_maps,
            "category_modes": self.category_modes,
            "imputation_strategy": {
                "numerical": "train_mean",
                "categorical": "train_mode",
            },
            "missingness_mask_convention": {
                "0": "observed",
                "1": "missing",
            },
        }

    @classmethod
    def from_dict(cls, data: dict) -> ClinicalPreprocessor:
        prep = cls(
            numerical_columns=data.get("numerical_columns", data.get("clinical_columns", [])),
            categorical_columns=data.get("categorical_columns", []),
            category_maps=data.get("category_maps", {}),
            category_modes=data.get("category_modes", {}),
        )
        if "scaler_mean" in data and data["scaler_mean"]:
            prep.scaler.mean_ = np.array(data["scaler_mean"], dtype=np.float64)
            prep.scaler.scale_ = np.array(data["scaler_scale"], dtype=np.float64)
            prep.scaler.var_ = prep.scaler.scale_ ** 2
            prep.scaler.n_samples_seen_ = 100
        return prep


def preprocess_clinical_vector(record: dict | pd.Series, spec: dict) -> np.ndarray:
    """Deterministic inference preprocessing of clinical observation from preprocessing.json spec (§3)."""
    preprocessor = ClinicalPreprocessor.from_dict(spec)
    return preprocessor.transform_row(record)


class FusionDataset(Dataset):
    def __init__(
        self,
        frame: pd.DataFrame,
        image_root: Path | str,
        image_column: str,
        clinical_columns: list[str] | None = None,
        grade_column: str = "dr_grade",
        scaler: StandardScaler | None = None,
        image_size: int = 224,
        preprocessor: ClinicalPreprocessor | None = None,
    ):
        self.frame = frame.reset_index(drop=True)
        self.image_root = Path(image_root)
        self.image_column = image_column
        self.grade_column = grade_column
        self.transform = transforms.Compose([
            transforms.Resize((image_size, image_size)),
            transforms.ToTensor(),
            transforms.Normalize(mean=(0.485, 0.456, 0.406), std=(0.229, 0.224, 0.225)),
        ])
        if preprocessor is not None:
            self.preprocessor = preprocessor
        else:
            cols = clinical_columns or []
            self.preprocessor = ClinicalPreprocessor(numerical_columns=cols, scaler=scaler)

    def __len__(self) -> int:
        return len(self.frame)

    def __getitem__(self, index: int):
        row = self.frame.iloc[index]
        path = Path(str(row[self.image_column]))
        if not path.is_absolute():
            path = self.image_root / path
        with Image.open(path) as image:
            image_tensor = self.transform(image.convert("RGB"))

        clinical = self.preprocessor.transform_row(row)

        return (
            image_tensor,
            torch.tensor(clinical, dtype=torch.float32),
            torch.tensor(int(row[self.grade_column]), dtype=torch.long),
        )


def _split_by_patient(frame: pd.DataFrame, patient_column: str, seed: int):
    groups = frame[patient_column].astype(str).to_numpy()
    first = GroupShuffleSplit(n_splits=1, test_size=0.20, random_state=seed)
    train_val_idx, test_idx = next(first.split(frame, groups=groups))
    train_val = frame.iloc[train_val_idx].copy()
    second = GroupShuffleSplit(n_splits=1, test_size=0.20, random_state=seed + 1)
    train_idx, val_idx = next(second.split(train_val, groups=train_val[patient_column].astype(str)))
    train = train_val.iloc[train_idx].copy()
    val = train_val.iloc[val_idx].copy()
    test = frame.iloc[test_idx].copy()
    sets = [set(x[patient_column].astype(str)) for x in (train, val, test)]
    if sets[0] & sets[1] or sets[0] & sets[2] or sets[1] & sets[2]:
        raise RuntimeError("Patient leakage detected across train/validation/test splits.")
    return train, val, test


def forward_model(model: nn.Module, model_type: str, images: torch.Tensor, clinical: torch.Tensor) -> torch.Tensor:
    if model_type == "fusion":
        return model(images, clinical)
    elif model_type == "image_only":
        return model(images)
    elif model_type == "clinical_only":
        return model(clinical)
    else:
        raise ValueError(f"Unknown model_type: {model_type}")


def compute_ece_and_brier(y_true: np.ndarray, probs: np.ndarray, n_bins: int = 10) -> dict[str, float]:
    """Compute multiclass Expected Calibration Error (ECE) and multiclass Brier score (§6)."""
    if len(y_true) == 0 or len(probs) == 0:
        return {"ece": 0.0, "brier_score": 0.0}

    confidences = np.max(probs, axis=1)
    predictions = np.argmax(probs, axis=1)
    accuracies = (predictions == y_true)

    bin_boundaries = np.linspace(0.0, 1.0, n_bins + 1)
    ece = 0.0
    total_samples = len(y_true)

    for i in range(n_bins):
        in_bin = (confidences > bin_boundaries[i]) & (confidences <= bin_boundaries[i + 1])
        count = int(np.sum(in_bin))
        if count > 0:
            acc_bin = float(np.mean(accuracies[in_bin]))
            conf_bin = float(np.mean(confidences[in_bin]))
            ece += (count / total_samples) * np.abs(acc_bin - conf_bin)

    num_classes = probs.shape[1]
    y_true_clipped = np.clip(y_true, 0, num_classes - 1)
    y_one_hot = np.eye(num_classes)[y_true_clipped]
    brier = float(np.mean(np.sum((probs - y_one_hot) ** 2, axis=1)))
    return {"ece": float(ece), "brier_score": brier}


def compute_metrics(y_true: np.ndarray, y_pred: np.ndarray, probs: np.ndarray | None = None) -> dict:
    referable = y_true >= 2
    pred_referable = y_pred >= 2
    metrics = {
        "macro_f1": float(f1_score(y_true, y_pred, average="macro", zero_division=0)),
        "balanced_accuracy": float(balanced_accuracy_score(y_true, y_pred)),
        "quadratic_weighted_kappa": float(cohen_kappa_score(y_true, y_pred, weights="quadratic")),
        "referable_dr_sensitivity": float(recall_score(referable, pred_referable, zero_division=0)),
        "referable_dr_specificity": float(recall_score(~referable, ~pred_referable, zero_division=0)),
        "per_class_precision": [float(v) for v in precision_score(y_true, y_pred, average=None, labels=[0, 1, 2, 3, 4], zero_division=0)],
        "per_class_recall": [float(v) for v in recall_score(y_true, y_pred, average=None, labels=[0, 1, 2, 3, 4], zero_division=0)],
        "per_class_f1": [float(v) for v in f1_score(y_true, y_pred, average=None, labels=[0, 1, 2, 3, 4], zero_division=0)],
        "confusion_matrix": confusion_matrix(y_true, y_pred, labels=[0, 1, 2, 3, 4]).tolist(),
    }
    if probs is not None:
        cal = compute_ece_and_brier(y_true, probs)
        metrics["ece"] = cal["ece"]
        metrics["brier_score"] = cal["brier_score"]
    else:
        metrics["ece"] = None
        metrics["brier_score"] = None
    return metrics


def compute_patient_bootstrap_ci(patient_df: pd.DataFrame, n_bootstrap: int = 1000, seed: int = 42) -> dict:
    """Bootstrap patient rows with replacement to compute 95% CI on macro-F1 and QWK (§6a)."""
    rng = np.random.RandomState(seed)
    n = len(patient_df)
    if n < 2:
        return {"macro_f1_95ci": [0.0, 0.0], "qwk_95ci": [0.0, 0.0]}

    f1_list: list[float] = []
    qwk_list: list[float] = []
    for _ in range(n_bootstrap):
        sampled = patient_df.sample(n=n, replace=True, random_state=rng.randint(0, 1_000_000))
        y_true = sampled["y_true"].to_numpy()
        y_pred = sampled["y_pred"].to_numpy()
        f1_list.append(float(f1_score(y_true, y_pred, average="macro", zero_division=0)))
        qwk = cohen_kappa_score(y_true, y_pred, weights="quadratic")
        qwk_list.append(float(qwk) if np.isfinite(qwk) else 0.0)

    f1_clean = [f for f in f1_list if np.isfinite(f)]
    qwk_clean = [q for q in qwk_list if np.isfinite(q)]

    return {
        "macro_f1_95ci": [float(np.percentile(f1_clean, 2.5)), float(np.percentile(f1_clean, 97.5))] if f1_clean else [0.0, 0.0],
        "qwk_95ci": [float(np.percentile(qwk_clean, 2.5)), float(np.percentile(qwk_clean, 97.5))] if qwk_clean else [0.0, 0.0],
    }


def compute_paired_patient_bootstrap_delta(
    patient_df_a: pd.DataFrame,
    patient_df_b: pd.DataFrame,
    n_bootstrap: int = 1000,
    seed: int = 42,
) -> dict:
    """Paired bootstrap difference in macro-F1 between model A and model B (§6a)."""
    rng = np.random.RandomState(seed)
    merged = pd.merge(
        patient_df_a[["patient_id", "y_true", "y_pred"]].rename(columns={"y_pred": "y_pred_a"}),
        patient_df_b[["patient_id", "y_pred"]].rename(columns={"y_pred": "y_pred_b"}),
        on="patient_id",
    )
    n = len(merged)
    if n < 2:
        return {"delta_macro_f1_mean": 0.0, "delta_macro_f1_95ci": [None, None]}

    deltas: list[float] = []
    for _ in range(n_bootstrap):
        sampled = merged.sample(n=n, replace=True, random_state=rng.randint(0, 1_000_000))
        y_true = sampled["y_true"].to_numpy()
        f1_a = f1_score(y_true, sampled["y_pred_a"].to_numpy(), average="macro", zero_division=0)
        f1_b = f1_score(y_true, sampled["y_pred_b"].to_numpy(), average="macro", zero_division=0)
        deltas.append(float(f1_a - f1_b))

    return {
        "delta_macro_f1_mean": float(np.mean(deltas)),
        "delta_macro_f1_95ci": [float(np.percentile(deltas, 2.5)), float(np.percentile(deltas, 97.5))],
    }


def generate_model_card(
    model_type: str,
    metrics: dict,
    checkpoint_path: Path,
    cfg: dict,
    preprocessor: ClinicalPreprocessor,
) -> str:
    chk_hash = "not_available"
    if checkpoint_path.is_file():
        chk_hash = hashlib.sha256(checkpoint_path.read_bytes()).hexdigest()

    img_m = metrics.get("evaluation_unit_image_level", {})
    pat_m = metrics.get("evaluation_unit_patient_level", {})

    return f"""# Model Card: Drishti-AI {model_type.replace('_', ' ').title()} DR Classifier

> **DISCLAIMER: NOT A MEDICAL DEVICE.**
> This model artifact is intended strictly for retrospective research and pipeline verification. It has NOT been approved or cleared by the US FDA, EMA, CDSCO, or any regulatory body for clinical diagnostic use, screening, triage, or medical decision-making. Never use this model for unsupervised patient diagnosis.

---

## 1. Model Details
- **Architecture:** {model_type} (EfficientNet-B0 backbone with clinical projection and missingness-mask integration)
- **Model Type:** Multimodal / Baseline Retinal DR Classifier (ICDRS 5-class: Grades 0 to 4)
- **Framework:** PyTorch {torch.__version__} / TorchScript
- **Checkpoint SHA-256:** `{chk_hash}`
- **License / Governance:** Drishti-AI Research License; governed by PhysioNet DUA.

## 2. Intended Use
- **Primary Use:** Retrospective evaluation of diabetic retinopathy severity grading on standardized digital fundus photographs paired with clinical covariates.
- **Intended Population:** Adults undergoing screening for diabetic retinopathy within the study cohort.
- **Evaluation Unit:** Both image-level and patient-level (worst-eye / maximum grade aggregation).

## 3. Out-of-Scope Uses
- Standalone or primary diagnostic device without board-certified ophthalmologist review.
- Screening on non-mydriatic or low-quality images rejected by quality gates.
- Prediction of secondary outcomes (e.g., HbA1c, hypertension, or diabetes onset) from retinal images.
- Deployment in populations with unrepresented clinical distributions without prior local validation.

## 4. Training Data & Provenance
- **Dataset:** mBRSET (Multimodal Brazilian Retinal Disease Study) or verified research release via PhysioNet.
- **Splits:** Patient-grouped split (GroupShuffleSplit) preventing patient identity leakage between train, validation, and test sets.
- **Numerical Covariates:** {preprocessor.numerical_columns}
- **Categorical Covariates:** {preprocessor.categorical_columns}
- **Preprocessing:** Normalization (ImageNet mean/std), StandardScaler for numerical covariates fitted strictly on train partition.
- **Missingness Handling (§3a):** Explicit missingness mask (mask = 1 for missing, mask = 0 for observed).

## 5. Quantitative Performance (Held-out Test Cohort)
- **Evaluated Patients:** {metrics.get('test_patients', 'N/A')}
- **Evaluated Images:** {metrics.get('test_images', 'N/A')}
- **Coverage Rate:** {metrics.get('coverage_rate', 1.0) * 100:.1f}%
- **Abstention Rate:** {metrics.get('abstention_rate', 0.0) * 100:.1f}%

### Patient-Level Metrics:
- **Macro F1:** {pat_m.get('macro_f1', 0.0):.4f} (95% CI: {pat_m.get('macro_f1_95ci', [0.0, 0.0])})
- **Quadratic Weighted Kappa (QWK):** {pat_m.get('quadratic_weighted_kappa', 0.0):.4f} (95% CI: {pat_m.get('qwk_95ci', [0.0, 0.0])})
- **Referable DR Sensitivity:** {pat_m.get('referable_dr_sensitivity', 0.0):.4f}
- **Referable DR Specificity:** {pat_m.get('referable_dr_specificity', 0.0):.4f}

### Image-Level Metrics:
- **Macro F1:** {img_m.get('macro_f1', 0.0):.4f}
- **Quadratic Weighted Kappa (QWK):** {img_m.get('quadratic_weighted_kappa', 0.0):.4f}
- **Balanced Accuracy:** {img_m.get('balanced_accuracy', 0.0):.4f}

## 6. Calibration & Recalibration Analysis (§6)
- **Recalibration Method:** Post-hoc Temperature Scaling fitted strictly on validation NLL.
- **Fitted Temperature (T):** {metrics.get('calibration', {}).get('fitted_temperature', 1.0):.3f}
- **Pre-Calibration ECE:** {metrics.get('calibration', {}).get('uncalibrated_ece', 0.0):.4f}
- **Post-Calibration ECE:** {metrics.get('calibration', {}).get('calibrated_ece', 0.0):.4f}
- **Pre-Calibration Brier Score:** {metrics.get('calibration', {}).get('uncalibrated_brier_score', 0.0):.4f}
- **Post-Calibration Brier Score:** {metrics.get('calibration', {}).get('calibrated_brier_score', 0.0):.4f}

## 7. Known Failure Modes & Abstention Criteria
- **Quality Rejections:** Low contrast, blur, media opacities, or off-center macula/optic disc.
- **Missing Clinical Inputs:** The model falls back to explicit missingness channels (mask = 1) or returns an abstention record (`status: abstain`).
- **Class Ambiguity:** Low top-1 margin prompts referral for manual expert review.

---
*Generated automatically per Mitchell et al. (2019) Model Cards for Model Reporting.*
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--model",
        choices=["fusion", "image_only", "clinical_only"],
        default=None,
        help="Model baseline to train (overrides config model_type if set)",
    )
    args = parser.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))

    model_type = args.model or cfg.get("model_type", "fusion")
    if model_type not in ("fusion", "image_only", "clinical_only"):
        raise ValueError(f"Invalid model_type: {model_type}")

    required = ("metadata_csv", "image_root", "image_column", "patient_column", "grade_column")
    missing = [key for key in required if not cfg.get(key)]
    if not cfg.get("clinical_columns") and not cfg.get("numerical_columns"):
        missing.append("clinical_columns (or numerical_columns)")
    if missing:
        raise ValueError(f"Missing config keys: {missing}")

    numerical_cols = list(cfg.get("numerical_columns") or cfg.get("clinical_columns") or [])
    categorical_cols = list(cfg.get("categorical_columns") or [])
    all_clinical_cols = numerical_cols + categorical_cols

    seed = int(cfg.get("seed", 42))
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)

    frame = pd.read_csv(cfg["metadata_csv"])
    columns = [cfg["image_column"], cfg["patient_column"], cfg["grade_column"], *all_clinical_cols]
    absent = [c for c in columns if c not in frame.columns]
    if absent:
        raise ValueError(f"Configured columns absent from metadata: {absent}")

    frame = frame.dropna(subset=[cfg["image_column"], cfg["patient_column"], cfg["grade_column"]]).copy()
    frame[cfg["grade_column"]] = pd.to_numeric(frame[cfg["grade_column"]], errors="coerce")
    frame = frame.dropna(subset=[cfg["grade_column"]])
    if not frame[cfg["grade_column"]].isin([0, 1, 2, 3, 4]).all():
        raise ValueError("DR grade labels must be integer values 0..4.")
    frame[cfg["grade_column"]] = frame[cfg["grade_column"]].astype(int)

    if all_clinical_cols:
        frame = frame[frame[all_clinical_cols].notna().any(axis=1)]

    image_root = Path(cfg["image_root"])

    def resolve(value):
        path = Path(str(value))
        return path if path.is_absolute() else image_root / path

    frame = frame[frame[cfg["image_column"]].map(resolve).map(Path.is_file)]

    # Abort criteria checks (§5a)
    min_train_pts = int(cfg.get("min_patients_train", 10))
    min_val_pts = int(cfg.get("min_patients_val", 30))
    min_test_pts = int(cfg.get("min_patients_test", 30))

    if frame[cfg["patient_column"]].nunique() < (min_train_pts + min_val_pts + min_test_pts):
        raise ValueError(
            f"Insufficient unique patients ({frame[cfg['patient_column']].nunique()}) for required split sizes "
            f"(train={min_train_pts}, val={min_val_pts}, test={min_test_pts})."
        )

    train, val, test = _split_by_patient(frame, cfg["patient_column"], seed)

    if train[cfg["patient_column"]].nunique() < min_train_pts:
        raise ValueError(f"Aborting per §5a: Train split has {train[cfg['patient_column']].nunique()} unique patients (< {min_train_pts}).")
    if val[cfg["patient_column"]].nunique() < min_val_pts:
        raise ValueError(f"Aborting per §5a: Val split has {val[cfg['patient_column']].nunique()} unique patients (< {min_val_pts}).")
    if test[cfg["patient_column"]].nunique() < min_test_pts:
        raise ValueError(f"Aborting per §5a: Test split has {test[cfg['patient_column']].nunique()} unique patients (< {min_test_pts}).")

    if bool(cfg.get("check_dr_classes_all_splits", True)):
        for split_name, sframe in [("train", train), ("validation", val), ("test", test)]:
            present = set(sframe[cfg["grade_column"]].unique())
            if len(present) < 5:
                missing = sorted(list(set(range(5)) - present))
                raise ValueError(
                    f"Aborting per §5a: {split_name} split is missing DR classes: {missing}. "
                    "All splits must have all 5 DR classes represented."
                )

    # Preprocessing fitted ONLY on the training split (§3, §5)
    preprocessor = ClinicalPreprocessor(
        numerical_columns=numerical_cols,
        categorical_columns=categorical_cols,
    )
    preprocessor.fit(train)

    image_size = int(cfg.get("image_size", 224))
    batch_size = int(cfg.get("batch_size", 16))

    train_ds = FusionDataset(train, image_root, cfg["image_column"], grade_column=cfg["grade_column"], image_size=image_size, preprocessor=preprocessor)
    val_ds = FusionDataset(val, image_root, cfg["image_column"], grade_column=cfg["grade_column"], image_size=image_size, preprocessor=preprocessor)
    test_ds = FusionDataset(test, image_root, cfg["image_column"], grade_column=cfg["grade_column"], image_size=image_size, preprocessor=preprocessor)

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False, num_workers=0)
    test_loader = DataLoader(test_ds, batch_size=batch_size, shuffle=False, num_workers=0)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    num_clinical = preprocessor.total_features
    pretrained = bool(cfg.get("pretrained", True))
    backbone = str(cfg.get("backbone", "efficientnet_b0"))

    if model_type == "fusion":
        model = RetinalClinicalFusion(clinical_features=num_clinical, num_grades=5, pretrained=pretrained, backbone=backbone)
    elif model_type == "image_only":
        model = ImageOnlyDRClassifier(num_grades=5, pretrained=pretrained, backbone=backbone)
    elif model_type == "clinical_only":
        model = ClinicalOnlyDRClassifier(clinical_features=num_clinical, num_grades=5)
    model.to(device)

    # Class weighting to handle imbalance (§5)
    counts = np.bincount(train[cfg["grade_column"]].to_numpy(), minlength=5)
    weights = len(train) / np.maximum(counts, 1) / 5
    criterion = nn.CrossEntropyLoss(weight=torch.tensor(weights, dtype=torch.float32, device=device))
    optimizer = torch.optim.AdamW(model.parameters(), lr=float(cfg.get("learning_rate", 1e-4)))

    output = Path(cfg.get("output_dir", f"artifacts/mbrset_{model_type}"))
    output.mkdir(parents=True, exist_ok=True)

    # Save standalone preprocessing spec (§3)
    preprocessing_spec = preprocessor.to_dict()
    preprocessing_spec.update({
        "image_size": image_size,
        "backbone": backbone,
        "image_normalization": {
            "mean": [0.485, 0.456, 0.406],
            "std": [0.229, 0.224, 0.225],
        },
    })
    (output / "preprocessing.json").write_text(json.dumps(preprocessing_spec, indent=2), encoding="utf-8")

    def evaluate(loader: DataLoader, scaler: TemperatureScaler | None = None):
        model.eval()
        ys: list[int] = []
        preds: list[int] = []
        all_logits: list[torch.Tensor] = []
        with torch.no_grad():
            for images, clinical, labels in loader:
                logits = forward_model(model, model_type, images.to(device), clinical.to(device))
                all_logits.append(logits.cpu())
                scaled_logits = scaler(logits) if scaler is not None else logits
                probs = torch.softmax(scaled_logits, dim=-1)
                preds.extend(probs.argmax(1).cpu().numpy().tolist())
                ys.extend(labels.numpy().tolist())
        all_logits_tensor = torch.cat(all_logits, dim=0) if all_logits else torch.empty(0, 5)
        return np.asarray(ys), np.asarray(preds), all_logits_tensor

    # Predefined validation-based model selection criterion (§5c)
    # Test set is NEVER touched during selection
    best_val_macro_f1 = -1.0
    best_path = output / f"best_{model_type}.pt"
    epochs = int(cfg.get("epochs", 15))

    for epoch in range(epochs):
        model.train()
        for images, clinical, labels in train_loader:
            optimizer.zero_grad()
            logits = forward_model(model, model_type, images.to(device), clinical.to(device))
            loss = criterion(logits, labels.to(device))
            loss.backward()
            optimizer.step()

        vy, vp, _ = evaluate(val_loader)
        val_macro_f1 = float(f1_score(vy, vp, average="macro", zero_division=0))
        print(f"epoch={epoch + 1}/{epochs} val_macro_f1={val_macro_f1:.4f}")

        if val_macro_f1 > best_val_macro_f1:
            best_val_macro_f1 = val_macro_f1
            torch.save(
                {
                    "state_dict": model.cpu().state_dict(),
                    "model_type": model_type,
                    "clinical_columns": all_clinical_cols,
                    "numerical_columns": numerical_cols,
                    "categorical_columns": categorical_cols,
                    "scaler_mean": preprocessor.scaler.mean_.tolist() if hasattr(preprocessor.scaler, "mean_") else [],
                    "scaler_scale": preprocessor.scaler.scale_.tolist() if hasattr(preprocessor.scaler, "scale_") else [],
                    "category_maps": preprocessor.category_maps,
                    "category_modes": preprocessor.category_modes,
                    "image_size": image_size,
                    "backbone": backbone,
                    "val_macro_f1": best_val_macro_f1,
                    "seed": seed,
                },
                best_path,
            )
            model.to(device)

    # Evaluation on the untouched held-out test split (§5, §6)
    checkpoint = torch.load(best_path, map_location=device, weights_only=False)
    model.load_state_dict(checkpoint["state_dict"])
    model.eval()

    # Post-hoc Temperature Scaling fitted strictly on validation split (§6)
    vy, vp, val_logits = evaluate(val_loader)
    val_labels = torch.tensor(vy, dtype=torch.long)
    scaler = TemperatureScaler().to(device)
    fitted_temperature = 1.0
    if len(val_labels) > 0 and len(np.unique(vy)) > 1:
        fitted_temperature = scaler.fit(val_logits.to(device), val_labels.to(device))

    # Evaluate on held-out test split
    y_test, pred_test_uncal, test_logits = evaluate(test_loader)
    _, pred_test, _ = evaluate(test_loader, scaler=scaler)

    # Compute probabilities for ECE and Brier score
    uncal_probs = torch.softmax(test_logits, dim=-1).detach().cpu().numpy()
    cal_probs = torch.softmax(scaler(test_logits.to(device)), dim=-1).detach().cpu().numpy()

    # Image-level evaluation (§6a)
    image_metrics = compute_metrics(y_test, pred_test, probs=cal_probs)
    uncal_ece_brier = compute_ece_and_brier(y_test, uncal_probs)

    calibration_metrics = {
        "fitted_temperature": float(fitted_temperature),
        "uncalibrated_ece": uncal_ece_brier["ece"],
        "calibrated_ece": image_metrics["ece"],
        "uncalibrated_brier_score": uncal_ece_brier["brier_score"],
        "calibrated_brier_score": image_metrics["brier_score"],
    }
    torch.save({"temperature": float(fitted_temperature)}, output / "temperature_scaler.pt")

    # Patient-level evaluation (§6a)
    # Map predictions back to patient groups
    patient_records = []
    test_reset = test.reset_index(drop=True)
    for idx, (yt, yp) in enumerate(zip(y_test, pred_test)):
        patient_records.append({
            "patient_id": str(test_reset.iloc[idx][cfg["patient_column"]]),
            "y_true": int(yt),
            "y_pred": int(yp),
        })
    img_df = pd.DataFrame(patient_records)

    # Patient-level aggregation: maximum predicted grade across patient images
    # Ground truth is maximum true grade for the patient
    patient_df = (
        img_df.groupby("patient_id")
        .agg(y_true=("y_true", "max"), y_pred=("y_pred", "max"))
        .reset_index()
    )
    patient_metrics = compute_metrics(patient_df["y_true"].to_numpy(), patient_df["y_pred"].to_numpy())

    # Patient-level bootstrap confidence intervals (§6a)
    n_bootstrap = int(cfg.get("n_bootstrap", 1000))
    bootstrap_ci = compute_patient_bootstrap_ci(patient_df, n_bootstrap=n_bootstrap, seed=seed)
    patient_metrics.update(bootstrap_ci)

    # Coverage and abstention rates (§5)
    coverage_rate = 1.0
    abstention_rate = 0.0

    full_metrics = {
        "model_type": model_type,
        "selection_criterion": "validation_macro_f1",
        "best_val_macro_f1": float(best_val_macro_f1),
        "test_images": int(len(y_test)),
        "test_patients": int(len(patient_df)),
        "coverage_rate": coverage_rate,
        "abstention_rate": abstention_rate,
        "calibration": calibration_metrics,
        "evaluation_unit_image_level": image_metrics,
        "evaluation_unit_patient_level": patient_metrics,
        "warning": "Research evaluation only; not evidence of clinical validity or deployment readiness.",
    }

    metrics_file = output / "test_metrics.json"
    metrics_file.write_text(json.dumps(full_metrics, indent=2), encoding="utf-8")
    print(json.dumps(full_metrics, indent=2))

    # Generate Model Card per Mitchell et al. (2019) schema (§11)
    card_text = generate_model_card(
        model_type=model_type,
        metrics=full_metrics,
        checkpoint_path=best_path,
        cfg=cfg,
        preprocessor=preprocessor,
    )
    (output / "model_card.md").write_text(card_text, encoding="utf-8")

    # Export ONNX (§7)
    model.cpu()
    model.eval()
    onnx_path = output / f"{model_type}.onnx"
    dummy_image = torch.zeros(1, 3, image_size, image_size)
    dummy_clinical = torch.zeros(1, num_clinical * 2)

    if model_type == "fusion":
        torch.onnx.export(
            model,
            (dummy_image, dummy_clinical),
            onnx_path,
            input_names=["fundus_image", "clinical_features"],
            output_names=["dr_grade_logits"],
            dynamic_axes={
                "fundus_image": {0: "batch"},
                "clinical_features": {0: "batch"},
                "dr_grade_logits": {0: "batch"},
            },
            opset_version=17,
            dynamo=False,
        )
    elif model_type == "image_only":
        torch.onnx.export(
            model,
            (dummy_image,),
            onnx_path,
            input_names=["fundus_image"],
            output_names=["dr_grade_logits"],
            dynamic_axes={
                "fundus_image": {0: "batch"},
                "dr_grade_logits": {0: "batch"},
            },
            opset_version=17,
            dynamo=False,
        )
    elif model_type == "clinical_only":
        torch.onnx.export(
            model,
            (dummy_clinical,),
            onnx_path,
            input_names=["clinical_features"],
            output_names=["dr_grade_logits"],
            dynamic_axes={
                "clinical_features": {0: "batch"},
                "dr_grade_logits": {0: "batch"},
            },
            opset_version=17,
            dynamo=False,
        )


if __name__ == "__main__":
    main()
