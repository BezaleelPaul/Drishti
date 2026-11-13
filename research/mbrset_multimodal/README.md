# mBRSET Multimodal DR Model (Research Scaffold)

This research pipeline is isolated from the shipped single-image screening application and operates under strict privacy and evidence contracts (§1b, §1c).

---

## 1. Scope and Target Distinction (§4a)

- **Primary Supervised Target:** Diabetic Retinopathy grade $\in \{0, 1, 2, 3, 4\}$.
- **Input Modalities:** Retinal fundus image (`[3, H, W]`) + tabular clinical measurements with explicit missingness masks (`[2 * K]`).
- **Target Separation:** Clinical attributes (e.g., age, diabetes duration, insulin dependence, hypertension, HbA1c) are treated exclusively as **input features**. They are not treated as secondary ground-truth prediction heads or standalone diagnostic labels. The existing diabetes-risk assessment in Drishti-AI remains an independent clinical pathway.

---

## 2. Privacy & PhysioNet DUA Compliance (§1b)

1. Access to mBRSET must be obtained by credentialed users through official PhysioNet procedures under the applicable Data Use Agreement (DUA).
2. Never commit retinal images, patient IDs, metadata CSVs, or identifiable derived data to Git.
3. Dataset-derived artifacts (split manifests, checkpoints, preprocessed vectors) reside exclusively in `.gitignore`'d paths (e.g., `artifacts/local/`).
4. Audits produce non-identifying aggregate summaries only (`mbrset_audit.json`).

---

## 3. Architecture & Missingness Convention (§3, §3a)

The module provides three comparable baselines (§5):
- **A. Image-only (`ImageOnlyDRClassifier`):** Modular vision backbone (EfficientNet-B0 default for CPU/mobile, or DINOv2 / ViT foundation encoder) $\to$ freshly initialized 5-grade DR logits (0–4).
- **B. Clinical-only (`ClinicalOnlyDRClassifier`):** Multi-layer perceptron receiving clinical values + explicit missingness masks $\to$ 5-grade DR logits.
- **C. Multimodal Fusion (`RetinalClinicalFusion`):** Dual-encoder fusion concatenating projected image features (256-d) and clinical features (64-d) $\to$ 5-grade DR logits.

### Calibration & Recalibration (§6)
- **Post-Hoc Recalibration:** Validation-fitted Temperature Scaling (`TemperatureScaler`) optimizes scalar $T > 0$ strictly on validation logits via L-BFGS minimizing NLL.
- **Reporting:** Pre- and post-calibration Expected Calibration Error (ECE) and Brier scores are tracked in `test_metrics.json` and `model_card.md`.
- **Threshold Calibration:** Clinical operating points for referable DR ($\ge \text{Grade } 2$) are derived from calibrated probabilities rather than raw uncalibrated argmax.

### Missingness Mask Convention (§3a) & Preprocessing
- **`mask = 1` indicates missing.**
- **`mask = 0` indicates observed.**
- Preprocessing imputers, category maps, modes, and scalers are fitted **strictly on the training split** and serialized in `preprocessing.json`.
- Supports both `numerical_columns` (standard-scaled, train-mean imputed) and `categorical_columns` (ordinal/category-encoded, train-mode imputed).
- Preprocessing at inference is deterministic and reproducible via `preprocess_clinical_vector(record, spec)`.
- Out-of-distribution or unseen categories at inference receive `mask = 1` (explicit missingness/abstention).
- Automatic generation of `model_card.md` conforming to Mitchell et al. (2019) model reporting standards.

---

## 4. Execution Workflow

### Step 1: Aggregate Dataset Audit
```bash
python -m research.mbrset_multimodal.audit_dataset \
  --root /path/to/mbrset \
  --metadata /path/to/mbrset/metadata.csv \
  --out artifacts/local/mbrset_audit.json
```

### Step 2: Training Baselines
Train each baseline with patient-level grouping and selection criteria:
```bash
# Image-only baseline
python -m research.mbrset_multimodal.train --config config.json --model image_only

# Clinical-only baseline
python -m research.mbrset_multimodal.train --config config.json --model clinical_only

# Multimodal fusion baseline
python -m research.mbrset_multimodal.train --config config.json --model fusion
```

### Configuration Schema (`config.json`)
```json
{
  "metadata_csv": "/path/to/mbrset/metadata.csv",
  "image_root": "/path/to/mbrset/images",
  "image_column": "image_path",
  "patient_column": "patient_id",
  "grade_column": "dr_grade",
  "clinical_columns": ["age", "diabetes_duration", "hba1c", "systolic_bp"],
  "image_size": 224,
  "epochs": 15,
  "batch_size": 16,
  "seed": 42,
  "learning_rate": 0.0001,
  "min_patients_train": 10,
  "min_patients_val": 30,
  "min_patients_test": 30,
  "output_dir": "artifacts/local/mbrset_fusion"
}
```

---

## 5. Evaluation Protocol & Model Selection (§5c, §6a)

- **Selection Criterion:** Validation macro-F1. The test split is held out and untouched until final evaluation.
- **Evaluation Units:** Both image-level and patient-level metrics are computed and reported separately. Multi-image patient predictions are aggregated via max-pooling.
- **Statistical Significance:** Paired patient-level bootstrap resampling (1,000 iterations) calculates 95% confidence intervals on $\Delta\text{macro-F1}$ between fusion and image-only baselines.
- **Export Readiness:** ONNX export is generated with static batch/feature signatures and dynamic batch axis.
- **Current Status:** Repository scaffold, architecture, training, and testing pipelines are verified and tested (283 passing unit tests). Real-data training is BLOCKED pending local placement of authorized mBRSET data.
