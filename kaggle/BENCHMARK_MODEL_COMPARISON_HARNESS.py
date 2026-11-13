#!/usr/bin/env python3
"""
================================================================================
KAGGLE / LOCAL MODEL BENCHMARK & COMPARISON HARNESS
================================================================================
Evaluates candidate Diabetic Retinopathy classification models on the SAME
stratified/full evaluation dataset under strict, author-aligned preprocessing
and evaluation contracts.

MODELS BENCHMARKED:
  1. Build A: Current shipped Keras model (final_model.keras, 224px, raw RGB)
  2. F-5: Retrained focal/weighted EfficientNetB0 (final_model_focal.keras, 224px)
  3. APTOS 5-Fold ONNX: senanurcetin/aptos-retinopathy-grader (384px/512px, fold-spread)
  4. DRDetect Ordinal ONNX: adarshcod30/drdetect-dr-screening (512px, Ben Graham + circle crop)
  5. CBAM EfficientNet-B0: Wijenayake-S/dr-severity-efficientnetb0-cbam (448px, Ben Graham sigma=20)
  6. Aldahmashi EfficientNet-B0: Aldahmashi/DR-EfficientNetB0 (224px, /255 + norm)

METRICS COMPUTED:
  - Quadratic Weighted Kappa (QWK)
  - Accuracy & Balanced Accuracy (Mean Recall)
  - Macro-F1 & Weighted-F1
  - Referable DR Sensitivity (Grade >= 2) & Specificity
  - Referable PPV, NPV
  - Expected Calibration Error (ECE) [Where probabilistic output exists]
  - Inference Latency (Mean, p50, p90, p99 ms per image)
  - Ensemble Spread / Disagreement (APTOS 5-fold)

OUTPUT ARTIFACTS:
  - model_comparison.csv
  - model_comparison.json
  - confusion_matrices/<model_id>_confusion.csv & .json
  - per_class_metrics/<model_id>_per_class.csv
  - prediction_distributions/<model_id>_distribution.csv & .json
  - latency/<model_id>_latency.json

USAGE:
  # On Kaggle:
  Paste entire file into a single GPU/CPU notebook cell and Run All.
  # Local CLI:
  python BENCHMARK_MODEL_COMPARISON_HARNESS.py --data-dir /path/to/aptos --max-samples 1200
================================================================================
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

# -----------------------------------------------------------------------------
# 1. DEPENDENCY BOOTSTRAP (Kaggle friendly)
# -----------------------------------------------------------------------------
REQUIRED_PKGS = ["onnxruntime", "huggingface_hub", "numpy", "Pillow", "opencv-python"]
for pkg in REQUIRED_PKGS:
    try:
        __import__(pkg.replace("-", "_").split("=")[0])
    except ImportError:
        print(f"[BOOTSTRAP] Installing missing package: {pkg}...")
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", pkg], check=False)

import cv2
import numpy as np
import onnxruntime as ort
from huggingface_hub import hf_hub_download, list_repo_files
from PIL import Image

# -----------------------------------------------------------------------------
# 2. CONFIGURATION & CONTRACTS
# -----------------------------------------------------------------------------
NUM_CLASSES = 5
CLASS_NAMES = ["0 - No DR", "1 - Mild", "2 - Moderate", "3 - Severe", "4 - Proliferative"]


@dataclass
class ModelOutput:
    model_id: str
    model_version: str
    grade: int
    probabilities: Optional[List[float]]  # None if ordinal / non-probabilistic
    referable_score: Optional[float]
    referable: bool
    uncertainty: Optional[float]
    latency_ms: float
    raw_output: Any = None


# -----------------------------------------------------------------------------
# 3. PREPROCESSING PRIMITIVES
# -----------------------------------------------------------------------------
def crop_black_border(image: np.ndarray, tol: int = 7) -> np.ndarray:
    """Tight crop around retinal circular mask ignoring dark surrounding pixels."""
    if image.ndim == 3:
        gray = cv2.cvtColor(image, cv2.COLOR_RGB2GRAY)
    else:
        gray = image
    mask = gray > tol
    if not mask.any():
        return image
    row_idx = np.where(mask.any(axis=1))[0]
    col_idx = np.where(mask.any(axis=0))[0]
    return image[row_idx[0]:row_idx[-1] + 1, col_idx[0]:col_idx[-1] + 1]


def circle_crop(image: np.ndarray) -> np.ndarray:
    """Crops and masks the retinal circle from the center."""
    h, w = image.shape[:2]
    radius = min(h, w) // 2
    cx, cy = w // 2, h // 2
    mask = np.zeros((h, w), dtype=np.uint8)
    cv2.circle(mask, (cx, cy), radius, 255, -1)
    res = cv2.bitwise_and(image, image, mask=mask)
    return res[cy - radius:cy + radius, cx - radius:cx + radius]


def ben_graham_enhance(image: np.ndarray, sigma: int = 20) -> np.ndarray:
    """Ben Graham's colour/contrast enhancement: img*4 - GaussianBlur*4 + 128."""
    blurred = cv2.GaussianBlur(image, (0, 0), sigma)
    enhanced = cv2.addWeighted(image, 4, blurred, -4, 128)
    return enhanced


def imagenet_normalize(img_01: np.ndarray) -> np.ndarray:
    """Standard ImageNet normalization: (x - mean) / std."""
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    return (img_01 - mean) / std


def softmax(x: np.ndarray) -> np.ndarray:
    """Numerically stable softmax."""
    e = np.exp(x - np.max(x))
    return e / np.sum(e)


# -----------------------------------------------------------------------------
# 4. UNIVERSAL KERAS LOADER & MODEL RUNNERS
# -----------------------------------------------------------------------------
def universal_load_keras_model(model_path: str):
    """Loads a Keras model across all TF / Keras 2 / Keras 3 versions robustly."""
    path_str = str(model_path)
    errs = []

    # Attempt 1: Standalone Keras (Keras 3 / Keras 2)
    try:
        import keras
        if hasattr(keras, "models") and hasattr(keras.models, "load_model"):
            try:
                return keras.models.load_model(path_str, compile=False, safe_mode=False)
            except TypeError:
                return keras.models.load_model(path_str, compile=False)
    except Exception as e:
        errs.append(f"keras.models: {e}")

    # Attempt 2: tf.keras.models.load_model
    try:
        import tensorflow as tf
        if hasattr(tf, "keras") and hasattr(tf.keras, "models") and hasattr(tf.keras.models, "load_model"):
            try:
                return tf.keras.models.load_model(path_str, compile=False, safe_mode=False)
            except TypeError:
                return tf.keras.models.load_model(path_str, compile=False)
    except Exception as e:
        errs.append(f"tf.keras.models: {e}")

    # Attempt 3: tf.keras.saving.load_model
    try:
        import tensorflow as tf
        if hasattr(tf, "keras") and hasattr(tf.keras, "saving") and hasattr(tf.keras.saving, "load_model"):
            try:
                return tf.keras.saving.load_model(path_str, compile=False, safe_mode=False)
            except TypeError:
                return tf.keras.saving.load_model(path_str, compile=False)
    except Exception as e:
        errs.append(f"tf.keras.saving: {e}")

    raise RuntimeError("Failed all Keras loader attempts: " + " | ".join(errs))


class BaseDRRunner:
    model_id: str = "base"
    model_version: str = "1.0.0"

    def load(self) -> bool:
        raise NotImplementedError

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        raise NotImplementedError


# --- Model 1: Build A (Shipped Keras Baseline) ---
class BuildARunner(BaseDRRunner):
    model_id = "build_a"
    model_version = "v1.0.0-shipped"

    def __init__(self, model_path: Optional[str] = None):
        self.model_path = model_path
        self.model = None

    def load(self) -> bool:
        candidates = [
            self.model_path,
            os.environ.get("BUILD_A_KERAS"),
            "final_model.keras",
            "models/final_model.keras",
            "/kaggle/input/aptos-model-artifacts/final_model.keras",
            "/kaggle/input/diabetic-retinopathy-models/final_model.keras",
        ]
        chosen = None
        for c in candidates:
            if c and Path(c).exists():
                chosen = Path(c)
                break

        if chosen is None:
            print(f"[{self.model_id}] 'final_model.keras' not found. Skipping Build A.")
            return False

        try:
            self.model = universal_load_keras_model(str(chosen))
            print(f"[{self.model_id}] Loaded successfully from: {chosen}")
            return True
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        img_resized = image_pil.resize((224, 224), Image.BICUBIC)
        arr = np.expand_dims(np.asarray(img_resized, dtype=np.float32), axis=0)
        preds = self.model.predict(arr, verbose=0)[0]
        t1 = time.perf_counter()

        probs = [float(p) for p in preds]
        grade = int(np.argmax(preds))
        ref_score = float(sum(preds[2:]))
        referable = grade >= 2 or ref_score >= 0.09
        uncertainty = float(1.0 - max(probs))

        return ModelOutput(
            model_id=self.model_id,
            model_version=self.model_version,
            grade=grade,
            probabilities=probs,
            referable_score=ref_score,
            referable=referable,
            uncertainty=uncertainty,
            latency_ms=(t1 - t0) * 1000.0,
            raw_output=probs,
        )


# --- Model 2: F-5 (Retrained Focal/Weighted Model) ---
class F5Runner(BaseDRRunner):
    model_id = "f5_retrained"
    model_version = "v1.1.0-focal"

    def __init__(self, model_path: Optional[str] = None):
        self.model_path = model_path
        self.model = None

    def load(self) -> bool:
        candidates = [
            self.model_path,
            os.environ.get("F5_KERAS"),
            "final_model_focal.keras",
            "models/final_model_focal.keras",
            "/kaggle/working/retrain_f5/final_model_focal.keras",
            "/kaggle/input/aptos-model-artifacts/final_model_focal.keras",
        ]
        chosen = None
        for c in candidates:
            if c and Path(c).exists():
                chosen = Path(c)
                break

        if chosen is None:
            print(f"[{self.model_id}] 'final_model_focal.keras' not found. Skipping F-5.")
            return False

        try:
            self.model = universal_load_keras_model(str(chosen))
            print(f"[{self.model_id}] Loaded successfully from: {chosen}")
            return True
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        img_resized = image_pil.resize((224, 224), Image.BILINEAR)
        arr = np.expand_dims(np.asarray(img_resized, dtype=np.float32), axis=0)
        preds = self.model.predict(arr, verbose=0)[0]
        t1 = time.perf_counter()

        probs = [float(p) for p in preds]
        grade = int(np.argmax(preds))
        ref_score = float(sum(preds[2:]))
        referable = grade >= 2 or ref_score >= 0.15
        uncertainty = float(1.0 - max(probs))

        return ModelOutput(
            model_id=self.model_id,
            model_version=self.model_version,
            grade=grade,
            probabilities=probs,
            referable_score=ref_score,
            referable=referable,
            uncertainty=uncertainty,
            latency_ms=(t1 - t0) * 1000.0,
            raw_output=probs,
        )


# --- Model 3: APTOS 5-Fold ONNX Ensemble ---
class Aptos5FoldEnsembleRunner(BaseDRRunner):
    model_id = "aptos_5fold_onnx"
    model_version = "senanurcetin/aptos-retinopathy-grader"
    hf_repo = "senanurcetin/aptos-retinopathy-grader"

    def __init__(self):
        self.sessions = []
        self.export_spec = {}
        self.input_size = 384
        # Author export.json calibrated regression cut-points
        self.thresholds = [0.668, 1.132, 2.324, 3.3]

    def load(self) -> bool:
        try:
            print(f"[{self.model_id}] Downloading artifacts from HF: {self.hf_repo}...")
            files = list_repo_files(self.hf_repo)
            onnx_files = sorted([f for f in files if f.endswith(".onnx")])
            if "export.json" in files:
                export_path = hf_hub_download(self.hf_repo, "export.json")
                with open(export_path, "r", encoding="utf-8") as f:
                    self.export_spec = json.load(f)
                self.input_size = self.export_spec.get("input_size", 384)
                if "thresholds" in self.export_spec and isinstance(self.export_spec["thresholds"], list):
                    self.thresholds = [float(t) for t in self.export_spec["thresholds"]]

            self.sessions = []
            for f in onnx_files:
                local_path = hf_hub_download(self.hf_repo, f)
                sess = ort.InferenceSession(str(local_path), providers=["CPUExecutionProvider"])
                self.sessions.append(sess)

            # Check input shape from first session
            inp_shape = self.sessions[0].get_inputs()[0].shape
            if len(inp_shape) == 4 and isinstance(inp_shape[2], int):
                self.input_size = inp_shape[2]

            print(f"[{self.model_id}] Loaded {len(self.sessions)} folds (input_size={self.input_size}, thresholds={self.thresholds})")
            return len(self.sessions) > 0
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def _decode_regression(self, score: float) -> int:
        grade = 0
        for th in self.thresholds:
            if score > th:
                grade += 1
        return min(4, max(0, grade))

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        img_resized = image_pil.resize((self.input_size, self.input_size), Image.BILINEAR)
        arr = np.asarray(img_resized, dtype=np.float32) / 255.0
        # NCHW format: (1, 3, H, W)
        x = np.transpose(arr, (2, 0, 1))
        x = np.expand_dims(x, axis=0).astype(np.float32)

        fold_raw = []
        for sess in self.sessions:
            inp_name = sess.get_inputs()[0].name
            out = sess.run(None, {inp_name: x})[0]
            fold_raw.append(out)

        t1 = time.perf_counter()

        # Check if output is scalar regression or 5-class logits
        first_out = np.asarray(fold_raw[0]).reshape(-1)
        if len(first_out) == 1:
            # Ordinal regression mode
            fold_scores = [float(np.squeeze(o)) for o in fold_raw]
            fold_grades = [self._decode_regression(s) for s in fold_scores]
            mean_score = float(np.mean(fold_scores))
            fold_spread = float(np.std(fold_grades))
            final_grade = self._decode_regression(mean_score)
            # Referable DR is grade >= 2 (i.e. score > second cut-point)
            referable = mean_score > self.thresholds[1]

            return ModelOutput(
                model_id=self.model_id,
                model_version=self.model_version,
                grade=final_grade,
                probabilities=None,  # Regression model: honest contract
                referable_score=mean_score,
                referable=referable,
                uncertainty=fold_spread,
                latency_ms=(t1 - t0) * 1000.0,
                raw_output={"fold_scores": fold_scores, "mean_score": mean_score, "fold_spread": fold_spread},
            )
        else:
            # 5-Class Logits mode fallback
            fold_preds = [softmax(np.asarray(o).reshape(-1)) for o in fold_raw]
            fold_preds_arr = np.stack(fold_preds)
            mean_probs = fold_preds_arr.mean(axis=0)
            fold_grades = [int(np.argmax(p)) for p in fold_preds_arr]
            fold_spread = float(np.std(fold_grades))
            grade = int(np.argmax(mean_probs))
            ref_score = float(mean_probs[2:].sum())
            referable = grade >= 2 or ref_score >= 0.5

            return ModelOutput(
                model_id=self.model_id,
                model_version=self.model_version,
                grade=grade,
                probabilities=[float(p) for p in mean_probs],
                referable_score=ref_score,
                referable=referable,
                uncertainty=fold_spread,
                latency_ms=(t1 - t0) * 1000.0,
                raw_output={"fold_preds": fold_preds_arr.tolist(), "fold_spread": fold_spread},
            )


# --- Model 4: DRDetect Ordinal Regression ONNX ---
class DRDetectOrdinalRunner(BaseDRRunner):
    model_id = "drdetect_ordinal"
    model_version = "adarshcod30/drdetect-dr-screening"
    hf_repo = "adarshcod30/drdetect-dr-screening"

    def __init__(self):
        self.session = None
        self.input_size = 512
        self.thresholds = [0.5, 1.5, 2.5, 3.5]  # Standard regression cut-points

    def load(self) -> bool:
        try:
            print(f"[{self.model_id}] Downloading ONNX from HF: {self.hf_repo}...")
            onnx_file = "efficientnet_b0_regression_512px.onnx"
            local_path = hf_hub_download(self.hf_repo, onnx_file)
            self.session = ort.InferenceSession(str(local_path), providers=["CPUExecutionProvider"])
            print(f"[{self.model_id}] Loaded successfully from: {local_path}")
            return True
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def preprocess_image(self, image_pil: Image.Image) -> np.ndarray:
        # Preprocessing: crop dark border -> circle crop -> Ben Graham -> resize 512x512 -> ImageNet norm
        img_rgb = np.asarray(image_pil.convert("RGB"), dtype=np.uint8)
        cropped = crop_black_border(img_rgb, tol=7)
        circled = circle_crop(cropped)
        enhanced = ben_graham_enhance(circled, sigma=20)
        resized = cv2.resize(enhanced, (self.input_size, self.input_size), interpolation=cv2.INTER_AREA)
        norm_01 = resized.astype(np.float32) / 255.0
        normalized = imagenet_normalize(norm_01)
        # NCHW format
        chw = np.transpose(normalized, (2, 0, 1))
        return np.expand_dims(chw, axis=0).astype(np.float32)

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        inp_tensor = self.preprocess_image(image_pil)
        inp_name = self.session.get_inputs()[0].name
        out = self.session.run(None, {inp_name: inp_tensor})[0]
        score = float(np.squeeze(out))
        t1 = time.perf_counter()

        # Ordinal regression threshold decoding
        grade = 0
        for th in self.thresholds:
            if score > th:
                grade += 1
        grade = min(4, max(0, grade))

        # Referable boundary is ICDR grade >= 2 (cut-point threshold 1.5)
        referable = score >= 1.5
        # Uncertainty: proximity to nearest decision threshold
        dist_to_boundary = min(abs(score - th) for th in self.thresholds)
        uncertainty = float(np.exp(-dist_to_boundary))

        return ModelOutput(
            model_id=self.model_id,
            model_version=self.model_version,
            grade=grade,
            probabilities=None,  # Ordinal regression model: no manufactured probabilities
            referable_score=score,
            referable=referable,
            uncertainty=uncertainty,
            latency_ms=(t1 - t0) * 1000.0,
            raw_output={"regression_score": score},
        )


# --- Model 5: CBAM Attention EfficientNet-B0 ---
class CBAMRunner(BaseDRRunner):
    model_id = "cbam_efficientnetb0"
    model_version = "Wijenayake-S/dr-severity-efficientnetb0-cbam"
    hf_repo = "Wijenayake-S/dr-severity-efficientnetb0-cbam"

    def __init__(self):
        self.model = None
        self.input_size = 448

    def load(self) -> bool:
        try:
            print(f"[{self.model_id}] Downloading Keras model from HF: {self.hf_repo}...")
            local_path = hf_hub_download(self.hf_repo, "dr_448.keras")
            self.model = universal_load_keras_model(str(local_path))
            print(f"[{self.model_id}] Loaded successfully from: {local_path}")
            return True
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def preprocess_image(self, image_pil: Image.Image) -> np.ndarray:
        # Preprocessing: crop black border (tol=7) -> resize 448 -> Ben Graham (sigma=20) -> /255
        img_rgb = np.asarray(image_pil.convert("RGB"), dtype=np.uint8)
        cropped = crop_black_border(img_rgb, tol=7)
        resized = cv2.resize(cropped, (self.input_size, self.input_size), interpolation=cv2.INTER_AREA)
        enhanced = ben_graham_enhance(resized, sigma=20)
        norm_01 = enhanced.astype(np.float32) / 255.0
        return np.expand_dims(norm_01, axis=0)

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        inp_tensor = self.preprocess_image(image_pil)
        preds = self.model.predict(inp_tensor, verbose=0)[0]
        t1 = time.perf_counter()

        probs = [float(p) for p in preds]
        grade = int(np.argmax(preds))
        ref_score = float(sum(preds[2:]))
        referable = grade >= 2 or ref_score >= 0.5
        uncertainty = float(1.0 - max(probs))

        return ModelOutput(
            model_id=self.model_id,
            model_version=self.model_version,
            grade=grade,
            probabilities=probs,
            referable_score=ref_score,
            referable=referable,
            uncertainty=uncertainty,
            latency_ms=(t1 - t0) * 1000.0,
            raw_output=probs,
        )


# --- Model 6: Aldahmashi EfficientNet-B0 ---
class AldahmashiRunner(BaseDRRunner):
    model_id = "aldahmashi_b0"
    model_version = "Aldahmashi/DR-EfficientNetB0"
    hf_repo = "Aldahmashi/DR-EfficientNetB0"

    def __init__(self):
        self.model = None
        self.input_size = 224

    def load(self) -> bool:
        try:
            print(f"[{self.model_id}] Downloading Keras model from HF: {self.hf_repo}...")
            local_path = hf_hub_download(self.hf_repo, "final_model.keras")
            self.model = universal_load_keras_model(str(local_path))
            print(f"[{self.model_id}] Loaded successfully from: {local_path}")
            return True
        except Exception as e:
            print(f"[{self.model_id}] Failed to load: {e}")
            return False

    def predict(self, image_pil: Image.Image) -> ModelOutput:
        t0 = time.perf_counter()
        img_resized = image_pil.resize((self.input_size, self.input_size), Image.BILINEAR)
        arr = np.expand_dims(np.asarray(img_resized, dtype=np.float32), axis=0)
        preds = self.model.predict(arr, verbose=0)[0]
        t1 = time.perf_counter()

        probs = [float(p) for p in preds]
        grade = int(np.argmax(preds))
        ref_score = float(sum(preds[2:]))
        referable = grade >= 2
        uncertainty = float(1.0 - max(probs))

        return ModelOutput(
            model_id=self.model_id,
            model_version=self.model_version,
            grade=grade,
            probabilities=probs,
            referable_score=ref_score,
            referable=referable,
            uncertainty=uncertainty,
            latency_ms=(t1 - t0) * 1000.0,
            raw_output=probs,
        )


# -----------------------------------------------------------------------------
# 5. METRIC CALCULATIONS & EVALUATION ENGINE
# -----------------------------------------------------------------------------
def compute_qwk(y_true: np.ndarray, y_pred: np.ndarray, num_classes: int = NUM_CLASSES) -> float:
    """Calculates Quadratic Weighted Kappa."""
    O = np.zeros((num_classes, num_classes), dtype=np.float64)
    for t, p in zip(y_true, y_pred):
        O[int(t), int(p)] += 1.0
    N = len(y_true)
    if N == 0:
        return 0.0
    O /= N
    E = np.outer(O.sum(axis=1), O.sum(axis=0))
    W = np.zeros((num_classes, num_classes), dtype=np.float64)
    for i in range(num_classes):
        for j in range(num_classes):
            W[i, j] = ((i - j) ** 2) / ((num_classes - 1) ** 2)
    denom = np.sum(W * E)
    if denom == 0:
        return 1.0
    return float(1.0 - (np.sum(W * O) / denom))


def compute_macro_f1(y_true: np.ndarray, y_pred: np.ndarray, num_classes: int = NUM_CLASSES) -> float:
    """Calculates unweighted Macro-F1 across all classes."""
    f1_list = []
    for c in range(num_classes):
        tp = np.sum((y_pred == c) & (y_true == c))
        fp = np.sum((y_pred == c) & (y_true != c))
        fn = np.sum((y_pred != c) & (y_true == c))
        prec = tp / max(1, tp + fp)
        rec = tp / max(1, tp + fn)
        f1 = (2 * prec * rec) / max(1e-9, prec + rec) if (prec + rec) > 0 else 0.0
        f1_list.append(f1)
    return float(np.mean(f1_list))


def compute_per_class_metrics(y_true: np.ndarray, y_pred: np.ndarray, num_classes: int = NUM_CLASSES) -> List[Dict[str, Any]]:
    """Calculates per-class precision, recall, F1, and support."""
    rows = []
    for c in range(num_classes):
        tp = int(np.sum((y_pred == c) & (y_true == c)))
        fp = int(np.sum((y_pred == c) & (y_true != c)))
        fn = int(np.sum((y_pred != c) & (y_true == c)))
        support = int(np.sum(y_true == c))
        prec = tp / max(1, tp + fp) if (tp + fp) > 0 else 0.0
        rec = tp / max(1, tp + fn) if (tp + fn) > 0 else 0.0
        f1 = (2 * prec * rec) / max(1e-9, prec + rec) if (prec + rec) > 0 else 0.0
        rows.append({
            "class_idx": c,
            "class_name": CLASS_NAMES[c],
            "precision": round(float(prec), 4),
            "recall": round(float(rec), 4),
            "f1_score": round(float(f1), 4),
            "support": support,
        })
    return rows


def compute_referable_metrics(y_true: np.ndarray, flags: List[bool]) -> Dict[str, float]:
    """Calculates sensitivity, specificity, PPV, NPV for referable DR (grade >= 2)."""
    tp = fp = tn = fn = 0
    for t, f in zip(y_true, flags):
        is_pos = t >= 2
        if is_pos and f:
            tp += 1
        elif is_pos and not f:
            fn += 1
        elif not is_pos and not f:
            tn += 1
        else:
            fp += 1
    sens = tp / max(1, tp + fn)
    spec = tn / max(1, tn + fp)
    ppv = tp / max(1, tp + fp)
    npv = tn / max(1, tn + fn)
    return {
        "referable_sensitivity": round(float(sens), 4),
        "referable_specificity": round(float(spec), 4),
        "referable_ppv": round(float(ppv), 4),
        "referable_npv": round(float(npv), 4),
        "tp": tp, "fp": fp, "tn": tn, "fn": fn
    }


def compute_ece(y_true: np.ndarray, probs_list: List[Optional[List[float]]], n_bins: int = 10) -> Optional[float]:
    """Calculates Expected Calibration Error for probabilistic outputs."""
    valid_probs = [p for p in probs_list if p is not None and len(p) == NUM_CLASSES]
    if len(valid_probs) != len(y_true):
        return None

    probs = np.array(valid_probs)
    conf = probs.max(axis=1)
    preds = probs.argmax(axis=1)
    correct = (preds == y_true).astype(float)
    bins = np.clip((conf * n_bins).astype(int), 0, n_bins - 1)

    ece_val = 0.0
    for b in range(n_bins):
        mask = bins == b
        if mask.sum() > 0:
            bin_acc = correct[mask].mean()
            bin_conf = conf[mask].mean()
            ece_val += mask.mean() * abs(bin_acc - bin_conf)
    return round(float(ece_val), 4)


# -----------------------------------------------------------------------------
# 6. DATASET LOADER & RECURSIVE DISCOVERY
# -----------------------------------------------------------------------------
def find_dataset_location(preferred_dir: Optional[Path] = None) -> Optional[Path]:
    """Recursively searches for dataset directories containing CSV and images."""
    if preferred_dir and preferred_dir.exists():
        # Check direct or subdirectories
        if (preferred_dir / "train.csv").exists():
            return preferred_dir
        for sub in preferred_dir.glob("**/train.csv"):
            return sub.parent

    # Candidate roots
    search_roots = [
        Path("/kaggle/input"),
        Path("/content"),
        Path("data"),
        Path("."),
    ]

    for root in search_roots:
        if not root.exists():
            continue
        # Search for any train.csv or *.csv with diagnosis/label
        for csv_path in root.glob("**/*.csv"):
            parent = csv_path.parent
            # Check if this parent or sibling has images
            img_dirs = [parent / "train_images", parent / "images", parent]
            for img_d in img_dirs:
                if img_d.exists() and any(img_d.glob("*.png")) or any(img_d.glob("*.jpg")) or any(img_d.glob("*.jpeg")):
                    return parent
    return None


def load_eval_dataset(data_dir: Path, max_samples: Optional[int] = None, seed: int = 42) -> List[Tuple[str, Path, int]]:
    """Loads and stratifies the labeled dataset, handling nested structures and format variations."""
    # If provided path doesn't have train.csv directly, try finding it
    if not (data_dir / "train.csv").exists():
        discovered = find_dataset_location(data_dir)
        if discovered:
            data_dir = discovered
            print(f"[DATA] Auto-discovered dataset root at: {data_dir}")

    # Look for any matching CSV
    train_csv = data_dir / "train.csv"
    if not train_csv.exists():
        csv_candidates = list(data_dir.glob("*.csv")) + list(data_dir.glob("**/*.csv"))
        if csv_candidates:
            train_csv = csv_candidates[0]
            print(f"[DATA] Using discovered metadata CSV: {train_csv}")
        else:
            # Print available input files to help user debug
            kaggle_inputs = []
            if Path("/kaggle/input").exists():
                for p in Path("/kaggle/input").glob("*"):
                    kaggle_inputs.append(str(p))
            raise FileNotFoundError(
                f"Could not find train.csv in '{data_dir}'.\n"
                f"Available folders under /kaggle/input: {kaggle_inputs}\n"
                f"Please ensure the 'APTOS 2019 Blindness Detection' dataset is added to this notebook via '+ Add Input'."
            )

    # Locate image directories
    possible_img_dirs = [
        train_csv.parent / "train_images",
        train_csv.parent / "images",
        train_csv.parent,
        data_dir / "train_images",
        data_dir / "images",
        data_dir,
    ]
    # Check parents and siblings
    for sub in data_dir.glob("**/train_images"):
        possible_img_dirs.append(sub)

    valid_img_dir = next((d for d in possible_img_dirs if d.exists() and (any(d.glob("*.png")) or any(d.glob("*.jpg")) or any(d.glob("*.jpeg")))), None)
    if valid_img_dir is None:
        valid_img_dir = data_dir

    rows = []
    with open(train_csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames or []
        id_col = next((c for c in ["id_code", "image", "image_name", "id", fields[0]] if c in fields), fields[0])
        diag_col = next((c for c in ["diagnosis", "dr_grade", "level", "label", fields[1]] if c in fields), fields[1] if len(fields) > 1 else fields[0])

        for r in reader:
            idc = str(r[id_col]).strip()
            # Remove extension if already in id_code
            base_id = Path(idc).stem
            try:
                label = int(r[diag_col])
            except (ValueError, TypeError):
                continue

            # Candidate extensions
            candidates = [
                valid_img_dir / f"{base_id}.png",
                valid_img_dir / f"{base_id}.jpg",
                valid_img_dir / f"{base_id}.jpeg",
                valid_img_dir / idc,
                data_dir / "train_images" / f"{base_id}.png",
                data_dir / f"{base_id}.png",
            ]
            img_path = next((p for p in candidates if p.exists()), None)
            if img_path:
                rows.append((base_id, img_path, label))

    if not rows:
        raise RuntimeError(
            f"No matching image files found for rows in {train_csv}.\n"
            f"Searched image directories: {[str(d) for d in possible_img_dirs if d.exists()]}"
        )

    if max_samples is not None and max_samples < len(rows):
        rng = np.random.RandomState(seed)
        strata: Dict[int, List[Tuple[str, Path, int]]] = {}
        for item in rows:
            strata.setdefault(item[2], []).append(item)
        per_class = max(1, max_samples // len(strata))
        eval_rows = []
        for label in sorted(strata.keys()):
            group = strata[label]
            rng.shuffle(group)
            eval_rows.extend(group[:per_class])
        rng.shuffle(eval_rows)
        return eval_rows[:max_samples]

    return rows


# -----------------------------------------------------------------------------
# 7. BENCHMARK EXECUTION & REPORTING
# -----------------------------------------------------------------------------
def run_benchmark(
    data_dir: Path,
    out_dir: Path,
    max_samples: Optional[int] = 1200,
    build_a_path: Optional[str] = None,
    f5_path: Optional[str] = None,
):
    print("=" * 78)
    print(" DIABETIC RETINOPATHY INTERCHANGEABLE MODEL BENCHMARK SUITE")
    print("=" * 78)

    out_dir.mkdir(parents=True, exist_ok=True)
    cm_dir = out_dir / "confusion_matrices"
    pcm_dir = out_dir / "per_class_metrics"
    pred_dir = out_dir / "prediction_distributions"
    lat_dir = out_dir / "latency"
    for d in [cm_dir, pcm_dir, pred_dir, lat_dir]:
        d.mkdir(parents=True, exist_ok=True)

    # 1. Load Data
    print(f"\n[DATA] Scanning dataset directory: {data_dir}...")
    eval_set = load_eval_dataset(data_dir, max_samples=max_samples)
    y_true = np.array([label for _, _, label in eval_set], dtype=np.int32)
    print(f"[DATA] Evaluation samples: {len(eval_set)} | Label counts: {np.bincount(y_true, minlength=5).tolist()}")

    # 2. Instantiate Candidate Runners
    candidate_runners: List[BaseDRRunner] = [
        BuildARunner(model_path=build_a_path),
        F5Runner(model_path=f5_path),
        Aptos5FoldEnsembleRunner(),
        DRDetectOrdinalRunner(),
        CBAMRunner(),
        AldahmashiRunner(),
    ]

    active_runners: List[BaseDRRunner] = []
    print("\n[MODELS] Initializing and verifying candidate model runners...")
    for runner in candidate_runners:
        print(f"\n--- Loading {runner.model_id} ({runner.model_version}) ---")
        if runner.load():
            active_runners.append(runner)
        else:
            print(f"Skipping {runner.model_id} (not available).")

    if not active_runners:
        print("\n[ERROR] No active model runners available to benchmark! Exiting.")
        return

    # 3. Execute Benchmarking
    print(f"\n[EVAL] Running {len(active_runners)} models over {len(eval_set)} evaluation images...")
    results_by_model: Dict[str, List[ModelOutput]] = {runner.model_id: [] for runner in active_runners}

    for idx, (idc, img_path, label) in enumerate(eval_set):
        img_pil = Image.open(img_path).convert("RGB")
        for runner in active_runners:
            try:
                output = runner.predict(img_pil)
                results_by_model[runner.model_id].append(output)
            except Exception as e:
                print(f"[ERROR] Inference failed on {idc} for {runner.model_id}: {e}")
                # Fallback zero output to preserve length
                results_by_model[runner.model_id].append(
                    ModelOutput(
                        model_id=runner.model_id,
                        model_version=runner.model_version,
                        grade=0,
                        probabilities=None,
                        referable_score=0.0,
                        referable=False,
                        uncertainty=1.0,
                        latency_ms=0.0,
                    )
                )
        if (idx + 1) % 100 == 0 or (idx + 1) == len(eval_set):
            print(f"  Processed {idx + 1}/{len(eval_set)} images ({(idx + 1) / len(eval_set) * 100:.1f}%)")

    # 4. Compute Metrics & Compile Reports
    summary_rows = []
    full_report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "dataset_size": len(eval_set),
        "ground_truth_distribution": np.bincount(y_true, minlength=5).tolist(),
        "models": {},
    }

    print("\n" + "=" * 78)
    print(f"{'Model':<22} | {'Acc':>6} | {'BalAcc':>6} | {'MacroF1':>7} | {'QWK':>6} | {'Sens':>6} | {'Spec':>6} | {'ECE':>6} | {'Lat(ms)':>7}")
    print("-" * 78)

    for runner in active_runners:
        mid = runner.model_id
        outputs = results_by_model[mid]
        y_pred = np.array([o.grade for o in outputs], dtype=np.int32)
        flags = [o.referable for o in outputs]
        probs_list = [o.probabilities for o in outputs]
        latencies = [o.latency_ms for o in outputs]

        # Core Metrics
        acc = np.mean(y_pred == y_true)
        bal_acc = np.mean([
            np.sum((y_pred == c) & (y_true == c)) / max(1, np.sum(y_true == c))
            for c in range(NUM_CLASSES)
        ])
        mf1 = compute_macro_f1(y_true, y_pred)
        kappa = compute_qwk(y_true, y_pred)
        ref_metrics = compute_referable_metrics(y_true, flags)
        ece_score = compute_ece(y_true, probs_list)
        per_class = compute_per_class_metrics(y_true, y_pred)

        # Confusion Matrix
        cm = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=int)
        for t, p in zip(y_true, y_pred):
            cm[int(t), int(p)] += 1

        # Latency Stats
        lat_stats = {
            "mean_ms": round(float(np.mean(latencies)), 2),
            "p50_ms": round(float(np.percentile(latencies, 50)), 2),
            "p90_ms": round(float(np.percentile(latencies, 90)), 2),
            "p99_ms": round(float(np.percentile(latencies, 99)), 2),
        }

        # Prediction Distribution
        pred_dist = np.bincount(y_pred, minlength=5).tolist()

        # Save artifacts
        # 1. Confusion Matrix
        with open(cm_dir / f"{mid}_confusion.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["True\\Pred"] + CLASS_NAMES)
            for i, row in enumerate(cm):
                writer.writerow([CLASS_NAMES[i]] + row.tolist())

        # 2. Per Class Metrics
        with open(pcm_dir / f"{mid}_per_class.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["class_idx", "class_name", "precision", "recall", "f1_score", "support"])
            writer.writeheader()
            writer.writerows(per_class)

        # 3. Prediction Distribution
        with open(pred_dir / f"{mid}_distribution.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["class_idx", "class_name", "true_count", "predicted_count"])
            for c in range(NUM_CLASSES):
                writer.writerow([c, CLASS_NAMES[c], int(np.sum(y_true == c)), pred_dist[c]])

        # 4. Latency
        with open(lat_dir / f"{mid}_latency.json", "w", encoding="utf-8") as f:
            json.dump(lat_stats, f, indent=2)

        # Append to summary
        summary_rows.append({
            "model_id": mid,
            "version": runner.model_version,
            "accuracy": round(float(acc), 4),
            "balanced_acc": round(float(bal_acc), 4),
            "macro_f1": round(float(mf1), 4),
            "qwk": round(float(kappa), 4),
            "referable_sensitivity": ref_metrics["referable_sensitivity"],
            "referable_specificity": ref_metrics["referable_specificity"],
            "referable_ppv": ref_metrics["referable_ppv"],
            "referable_npv": ref_metrics["referable_npv"],
            "ece": ece_score if ece_score is not None else "N/A (Ordinal)",
            "latency_p50_ms": lat_stats["p50_ms"],
            "latency_mean_ms": lat_stats["mean_ms"],
        })

        full_report["models"][mid] = {
            "version": runner.model_version,
            "metrics": summary_rows[-1],
            "confusion_matrix": cm.tolist(),
            "per_class": per_class,
            "prediction_distribution": pred_dist,
            "latency": lat_stats,
        }

        ece_str = f"{ece_score:.4f}" if ece_score is not None else "   N/A"
        print(
            f"{mid:<22} | {acc * 100:>5.1f}% | {bal_acc * 100:>5.1f}% | {mf1:>7.4f} | {kappa:>6.4f} | "
            f"{ref_metrics['referable_sensitivity']:>6.4f} | {ref_metrics['referable_specificity']:>6.4f} | "
            f"{ece_str:>6} | {lat_stats['p50_ms']:>7.2f}"
        )

    print("=" * 78)

    # 5. Save Global Comparison Reports
    csv_out = out_dir / "model_comparison.csv"
    with open(csv_out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary_rows[0].keys()))
        writer.writeheader()
        writer.writerows(summary_rows)

    json_out = out_dir / "model_comparison.json"
    with open(json_out, "w", encoding="utf-8") as f:
        json.dump(full_report, f, indent=2)

    print(f"\n[ARTIFACTS] Exported comparison results:")
    print(f"  - Summary CSV:       {csv_out}")
    print(f"  - Full Report JSON:  {json_out}")
    print(f"  - Confusion Matrices: {cm_dir}")
    print(f"  - Per-Class Metrics:  {pcm_dir}")
    print(f"  - Distributions:      {pred_dir}")
    print(f"  - Latency Profiles:   {lat_dir}")


# -----------------------------------------------------------------------------
# 8. ENTRY POINT & JUPYTER / COLAB / KAGGLE COMPATIBILITY
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DR Screening Interchangeable Model Benchmark")
    parser.add_argument(
        "--data-dir",
        type=str,
        default=os.environ.get("APTOS_DATA_DIR", ""),
        help="Path to labeled APTOS dataset containing train.csv and train_images/",
    )
    parser.add_argument(
        "--out-dir",
        type=str,
        default=os.environ.get("OUTPUT_DIR", ""),
        help="Output directory to write results and artifacts",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=1200,
        help="Maximum stratified evaluation samples (0 or None for full dataset)",
    )
    parser.add_argument(
        "--build-a-path",
        type=str,
        default=None,
        help="Path to final_model.keras for Build A baseline",
    )
    parser.add_argument(
        "--f5-path",
        type=str,
        default=None,
        help="Path to final_model_focal.keras for F-5 model",
    )

    # Use parse_known_args to gracefully ignore Jupyter/Colab/IPython kernel -f flags
    args, unknown = parser.parse_known_args()

    # Smart dataset directory detection (Kaggle / Colab / Local)
    data_dir_candidate = args.data_dir
    if not data_dir_candidate or not Path(data_dir_candidate).exists():
        search_paths = [
            Path("/kaggle/input/aptos2019-blindness-detection"),
            Path("/kaggle/input/aptos-2019-blindness-detection"),
            Path("/content/aptos2019-blindness-detection"),
            Path("/content/aptos-2019-blindness-detection"),
            Path("/content/data"),
            Path("data/aptos2019"),
            Path("data/raw/aptos2019"),
            Path("data"),
            Path("test_samples"),
        ]
        chosen_data_path = None
        for p in search_paths:
            if p.exists() and ((p / "train.csv").exists() or list(p.glob("*.csv"))):
                chosen_data_path = p
                break
        if chosen_data_path is None:
            chosen_data_path = Path("/kaggle/input/aptos2019-blindness-detection")
    else:
        chosen_data_path = Path(data_dir_candidate)

    # Smart output directory detection
    out_dir_candidate = args.out_dir
    if not out_dir_candidate:
        if Path("/kaggle/working").exists():
            chosen_out_path = Path("/kaggle/working/model_benchmark_results")
        elif Path("/content").exists():
            chosen_out_path = Path("/content/model_benchmark_results")
        else:
            chosen_out_path = Path("./model_benchmark_results")
    else:
        chosen_out_path = Path(out_dir_candidate)

    max_samples = None if args.max_samples <= 0 else args.max_samples

    print(f"[CONFIG] Dataset path: {chosen_data_path}")
    print(f"[CONFIG] Output path:  {chosen_out_path}")
    print(f"[CONFIG] Max samples:  {max_samples if max_samples else 'Full Dataset'}")

    run_benchmark(
        data_dir=chosen_data_path,
        out_dir=chosen_out_path,
        max_samples=max_samples,
        build_a_path=args.build_a_path,
        f5_path=args.f5_path,
    )

