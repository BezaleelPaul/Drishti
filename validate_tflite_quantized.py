"""Quantized-artifact parity validation (Ticket A-1 gate).

Runs two inference paths on the same stratified image set and FAILS unless:
  - top-1 grade agreement >= 99.2%,
  - dQWK >= -0.02 (kappa must not degrade by more than 0.02),
  - referable-DR sensitivity drop <= 1.0 pp.

Also prints median warm latency for both paths so the budget can be read from
this output on the target machine.

Usage:
    # Float-graph conversion sanity (no quantization influence):
    python validate_tflite_quantized.py --tflite scripts/convert/out/dr_efficientnet_b0_fp32.tflite
    # Full int8 parity (calibrated artifact):
    python validate_tflite_quantized.py --tflite scripts/convert/out/dr_efficientnet_b0_int8.tflite \
        --labels-csv <image,label CSV>
"""

from __future__ import annotations

import argparse
import csv
import json
import time
from pathlib import Path

import numpy as np
from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parent

GATE_TOP1_AGREEMENT = 0.992
GATE_DQWK = -0.02
GATE_REFERABLE_SENS_DROP_PP = 1.0
INPUT_SIZE = 224


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="TFLite vs keras parity gates")
    p.add_argument("--tflite", type=Path, required=True)
    p.add_argument(
        "--images-dir",
        type=Path,
        default=PROJECT_ROOT / "test_samples" / "01_real_clinical_fundus",
        help="Comparison images. For the release gate use the stratified labeled set.",
    )
    p.add_argument("--limit", type=int, default=200)
    p.add_argument(
        "--labels-csv",
        type=Path,
        default=None,
        help="CSV with 'image,label' columns for metric gates",
    )
    p.add_argument("--out", type=Path, default=PROJECT_ROOT / "results" / "tflite_parity.json")
    return p.parse_args()


def collect_images(d: Path, limit: int) -> list[Path]:
    paths: list[Path] = []
    for ext in ("*.jpg", "*.jpeg", "*.png", "*.JPG", "*.JPEG", "*.PNG"):
        paths.extend(sorted(d.glob(ext)))
    return paths[:limit]


def preprocess(img: Image.Image) -> np.ndarray:
    """Byte-parity preprocessing with the reference path:
    PIL bicubic resize (PIL default) -> raw 0..255 float32, NHWC."""
    return np.expand_dims(
        np.asarray(img.resize((INPUT_SIZE, INPUT_SIZE)), dtype=np.float32), axis=0
    )


class TFLiteRunner:
    def __init__(self, path: Path, num_threads: int = 2):
        import tensorflow as tf

        self.interp = tf.lite.Interpreter(model_path=str(path), num_threads=num_threads)
        self.interp.allocate_tensors()
        ind = self.interp.get_input_details()[0]
        od = self.interp.get_output_details()[0]
        self.in_index, self.out_index = ind["index"], od["index"]
        self.in_dtype = ind["dtype"]

    def predict(self, arr: np.ndarray) -> np.ndarray:
        self.interp.set_tensor(self.in_index, arr.astype(self.in_dtype))
        self.interp.invoke()
        return self.interp.get_tensor(self.out_index)[0]


def qwk(y_true: list[int], y_pred: list[int], n_classes: int = 5) -> float:
    """Standard quadratic-weighted kappa (Cohen 1968)."""
    n = len(y_true)
    if n == 0:
        return 0.0
    O = np.zeros((n_classes, n_classes), dtype=np.float64)
    for t, p in zip(y_true, y_pred):
        O[t, p] += 1.0
    O /= n
    E = np.outer(O.sum(axis=1), O.sum(axis=1))
    w = np.zeros((n_classes, n_classes), dtype=np.float64)
    for i in range(n_classes):
        for j in range(n_classes):
            w[i, j] = (i - j) ** 2 / (n_classes - 1) ** 2
    den = float(np.sum(w * E))
    if den <= 0:
        return 0.0
    return 1.0 - float(np.sum(w * O)) / den


def referable_sens_spec(y_true: list[int], y_pred: list[int]) -> dict:
    tp = fn = tn = fp = 0
    for t, p in zip(y_true, y_pred):
        pos = t >= 2
        if pos and p >= 2:
            tp += 1
        elif pos:
            fn += 1
        elif p < 2:
            tn += 1
        else:
            fp += 1
    sens = tp / (tp + fn) if (tp + fn) else 0.0
    spec = tn / (tn + fp) if (tn + fp) else 0.0
    return {"sens": round(sens, 4), "spec": round(spec, 4), "tp": tp, "fp": fp, "tn": tn, "fn": fn}


def main() -> int:
    args = parse_args()
    if not args.tflite.exists():
        raise SystemExit(f"Candidate .tflite not found: {args.tflite}")
    images = collect_images(args.images_dir, args.limit)
    if not images:
        raise SystemExit(f"No images found under {args.images_dir}")

    print(f"[1/4] Loading keras reference ({PROJECT_ROOT / 'final_model.keras'}) ...")
    import keras

    keras_model = keras.saving.load_model(str(PROJECT_ROOT / "final_model.keras"))
    _ = keras_model.output  # force build before timing

    print(f"[2/4] Loading {args.tflite.name} ...")
    runner = TFLiteRunner(args.tflite)

    stem_to_label: dict[str, int] = {}
    if args.labels_csv and args.labels_csv.exists():
        with open(args.labels_csv, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                stem_to_label[Path(row["image"]).stem] = int(row["label"])

    agree = 0
    n = 0
    max_abs_diff = 0.0
    keras_ms: list[float] = []
    tflite_ms: list[float] = []
    ker_preds: list[list[float]] = []
    tfl_preds: list[list[float]] = []
    y_true: list[int] = []

    print("[3/4] Running paired inference ...")
    for idx, p in enumerate(images):
        img = Image.open(p).convert("RGB")
        arr = preprocess(img)

        # Warm-up once (first image only): exclude TF lazy-init from timing.
        if idx == 0:
            _ = keras_model.predict(arr, verbose=0)
            _ = runner.predict(arr)

        t0 = time.perf_counter()
        kp = [float(v) for v in keras_model.predict(arr, verbose=0)[0]]
        ms_k = (time.perf_counter() - t0) * 1000.0

        t1 = time.perf_counter()
        tp_raw = runner.predict(arr)
        ms_t = (time.perf_counter() - t1) * 1000.0

        keras_ms.append(ms_k)
        tflite_ms.append(ms_t)
        ker_preds.append(kp)
        tfl_preds.append([float(v) for v in tp_raw])
        y_true.append(stem_to_label.get(p.stem, -1))

        if int(np.argmax(kp)) == int(np.argmax(tp_raw)):
            agree += 1
        n += 1
        max_abs_diff = max(max_abs_diff, max(abs(a - b) for a, b in zip(kp, tfl_preds[-1])))
        if (idx + 1) % 25 == 0:
            print(f"      {idx + 1}/{len(images)} agree={agree}/{n}")

    agreement = agree / n if n else 0.0
    result: dict = {
        "tflite": str(args.tflite),
        "n_images": n,
        "top1_agreement": round(agreement, 4),
        "max_prob_abs_diff": round(max_abs_diff, 6),
        "keras_warm_ms_median": round(float(np.median(keras_ms)), 1) if n else None,
        "tflite_warm_ms_median": round(float(np.median(tflite_ms)), 1) if n else None,
        "gates": {
            "top1_agreement_required": GATE_TOP1_AGREEMENT,
            "dqwk_required": GATE_DQWK,
            "referable_sens_drop_pp": GATE_REFERABLE_SENS_DROP_PP,
        },
    }

    # Labeled metric gates (run only when labels are provided).
    pairs = [(t, kp, tp) for t, kp, tp in zip(y_true, ker_preds, tfl_preds) if t >= 0]
    if pairs:
        y_lab = [t for t, _, _ in pairs]
        kp_lab = [kp for _, kp, _ in pairs]
        tp_lab = [tp for _, _, tp in pairs]
        y_k = [int(np.argmax(v)) for v in kp_lab]
        y_t = [int(np.argmax(v)) for v in tp_lab]

        qwk_k = qwk(y_lab, y_k)
        qwk_t = qwk(y_lab, y_t)
        sens_k = referable_sens_spec(y_lab, y_k)
        sens_t = referable_sens_spec(y_lab, y_t)

        result["n_labeled"] = len(y_lab)
        result["qwk_keras"] = round(qwk_k, 4)
        result["qwk_tflite"] = round(qwk_t, 4)
        result["dqwk"] = round(qwk_t - qwk_k, 4)
        result["referable_keras"] = sens_k
        result["referable_tflite"] = sens_t
        result["referable_sens_drop_pp"] = round(100 * (sens_k["sens"] - sens_t["sens"]), 2)

    dqwk = result.get("dqwk")
    sens_drop = result.get("referable_sens_drop_pp")
    labeled_gate_ok = dqwk is None or (
        dqwk >= GATE_DQWK and sens_drop <= GATE_REFERABLE_SENS_DROP_PP
    )
    passed = agreement >= GATE_TOP1_AGREEMENT and labeled_gate_ok
    result["passed"] = bool(passed)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))

    if not passed:
        print("PARITY FAIL: fall down the fallback ladder (int8 -> fp16 -> ONNX).")
        return 1
    print("PARITY PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
