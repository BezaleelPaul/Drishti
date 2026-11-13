# Test Suite Documentation — Drishti-AI

This document catalogs the test suite and documents test modifications and protocol conformance per §9b and §11 of the Drishti-AI Master Contract.

## Test Directory Structure

- `tests/contract/`: Schema, payload wire format, and failure injection contracts (e.g., ICDRS criteria, evidence schemas).
- `tests/edge_cases/`: Extreme edge cases, blank/corrupt image inputs, missing metadata.
- `tests/integration/`: End-to-end integration across API contracts, de-identified sync, ML quality, review markers, and pipeline flow.
- `tests/red_team/`: Safety invariants, domain gating, corpus sweeps, and adversarial inputs.
- `tests/unit/`: Component-level unit test suites for AI bridge, classifier, confidence, disagreement, FHIR export, grading policy, image I/O, OOD detection, quality scoring, retention, and TTA.

## Recent Test Modifications & Additions

### 1. `tests/unit/test_mbrset_dataset_audit.py` (Modified)
- **Rationale**: Extended audit verification to validate non-identifying aggregate image linkage verification and patient cohort aggregation statistics without emitting patient-level identifiers or row data.
- **Assertions Added**:
  - Image linkage stats: `referenced_in_metadata`, `matched_on_disk`, `missing_from_disk`.
  - Patient cohort stats: `unique_patients`, `multi_image_patient_count`, `max_images_per_patient`, `min_images_per_patient`.

### 2. `tests/unit/test_multimodal_pipeline.py` (Added)
- **Rationale**: Regression and contract test suite for the mBRSET multimodal DR research pipeline (§3, §5, §6).
- **Test Classes**:
  - `TestModelArchitectures`:
    - `test_image_only_classifier_forward`: Forward pass shape `[batch, 5]`.
    - `test_clinical_only_classifier_forward_and_validation`: Input validation requiring `[batch, clinical_features * 2]`, fails closed on odd/invalid dimensions.
    - `test_retinal_clinical_fusion_forward_and_validation`: Fusion forward pass and input dimension validation.
  - `TestPreprocessingAndMissingnessConvention`:
    - `test_missingness_mask_convention`: Confirms `mask = 1` indicates missing, `mask = 0` indicates observed (§3a), and standard scalers fit strictly on training splits.
    - `test_categorical_preprocessing_and_missingness`: Verifies categorical clinical encoding, train-mode imputation, and §3a missingness mask convention.
    - `test_preprocess_clinical_vector_parity`: Confirms inference preprocessing from serialized `preprocessing.json` matches training-time preprocessor identically.
  - `TestPatientSplitAndLeakage`:
    - `test_split_by_patient_prevents_leakage`: Confirms disjoint patient sets between train, val, and test splits.
  - `TestEvaluationUnitAndBootstrap`:
    - `test_metrics_and_bootstrap_ci`: Image-level and patient-level aggregation and 95% bootstrap confidence interval calculation (§6a).
    - `test_paired_patient_bootstrap_delta`: Paired patient-level bootstrap difference ($\Delta\text{macro-F1}$) between models (§6a).
  - `TestTrainingExecution`:
    - `test_train_aborts_on_insufficient_patients_per_5a`: Verifies pipeline fails closed / aborts when split patient counts fall below §5a thresholds.
    - `test_train_clinical_only_and_fusion_success`: End-to-end scaffold execution verifying training, serialization of `preprocessing.json`, `test_metrics.json`, `model_card.md` (Mitchell et al. 2019 schema), PyTorch checkpoints, and ONNX exports.

  - `TestCalibrationAndScaling`:
    - `test_temperature_scaler_reduces_nll_and_clamps`: Verifies post-hoc temperature scaling optimizes temperature on validation logits and clamps within valid bounds.
    - `test_compute_ece_and_brier`: Confirms multi-class Expected Calibration Error and Brier score evaluation logic.

## Test Protocol Compliance (§9b)

- **No Weakened Tests**: No existing tests were disabled, loosened, skipped, or marked `xfail`.
- **Suite Pass Rate**: 287 / 287 tests passing cleanly across the entire repository.
