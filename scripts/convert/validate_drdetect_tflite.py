"""Parity gate: TFLite conversion of the DRDetect ordinal model vs the ONNX
reference. Mirrors validate_tflite_quantized.py's honesty contract for the
Keras artifact — the TFLite file ships ONLY if this gate passes.

Gates (documented tolerances):
  - top-1 grade agreement  >= 99.2%   (same gate as the Keras fp32 path)
  - max |score diff|       <= 0.05    (continuous ordinal score; 0.05 is
                                       ~1/10th of the smallest inter-threshold
                                       gap of 1.0, so decode is preserved)
Decode: cut-points [0.5, 1.5, 2.5, 3.5] identical to classifier.py.

Usage:
    venv\\Scripts\\python.exe scripts\\convert\\validate_drdetect_tflite.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ONNX_PATH = ROOT / "models" / "efficientnet_b0_regression_512px.onnx"
TFLITE_PATH = (
    ROOT
    / "scripts"
    / "convert"
    / "out"
    / "drdetect_tflite"
    / "efficientnet_b0_regression_512px_float32.tflite"
)
IMAGE_DIRS = [
    ROOT / "test_samples" / "01_real_clinical_fundus",
    ROOT / "test_samples" / "curated",
]
OUT_PATH = ROOT / "results" / "drdetect_tflite_parity.json"

GATE_TOP1_AGREEMENT = 0.992
GATE_MAX_SCORE_DIFF = 0.05
sys.path.insert(0, str(ROOT))
from src.classification.drdetect_contract import THRESHOLDS


def decode_grade(score: float) -> int:
    return min(4, max(0, sum(1 for th in THRESHOLDS if score > th)))


def preprocess(pil_img: Image.Image) -> np.ndarray:
    """Identical to classifier._predict_onnx_drdetect preprocessing."""
    import cv2

    img_rgb = np.asarray(pil_img.convert("RGB"), dtype=np.uint8)
    gray = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
    mask = gray > 7
    if mask.any():
        row_idx = np.where(mask.any(axis=1))[0]
        col_idx = np.where(mask.any(axis=0))[0]
        cropped = img_rgb[row_idx[0] : row_idx[-1] + 1, col_idx[0] : col_idx[-1] + 1]
    else:
        cropped = img_rgb

    h, w = cropped.shape[:2]
    radius = min(h, w) // 2
    cx, cy = w // 2, h // 2
    circ_mask = np.zeros((h, w), dtype=np.uint8)
    cv2.circle(circ_mask, (cx, cy), radius, 255, -1)
    circled = cv2.bitwise_and(cropped, cropped, mask=circ_mask)[
        cy - radius : cy + radius, cx - radius : cx + radius
    ]

    blurred = cv2.GaussianBlur(circled, (0, 0), 20)
    enhanced = cv2.addWeighted(circled, 4, blurred, -4, 128)
    resized = cv2.resize(enhanced, (512, 512), interpolation=cv2.INTER_AREA)

    norm_01 = resized.astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    normalized = (norm_01 - mean) / std
    return np.transpose(normalized, (2, 0, 1))[None].astype(np.float32)


def main() -> int:
    import tensorflow as tf

    onnx_sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    onnx_inp = onnx_sess.get_inputs()[0].name

    interp = tf.lite.Interpreter(model_path=str(TFLITE_PATH))
    interp.allocate_tensors()
    inp_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]
    print(f"TFLite input : shape={inp_detail['shape']} dtype={inp_detail['dtype']}")
    print(f"TFLite output: shape={out_detail['shape']} dtype={out_detail['dtype']}")
    print(f"ONNX  input  : shape={onnx_sess.get_inputs()[0].shape}")

    nhwc = list(inp_detail["shape"]) == [1, 512, 512, 3]
    print(f"Input layout : {'NHWC (transposed by onnx2tf)' if nhwc else 'NCHW'}")

    images: list[Path] = []
    for d in IMAGE_DIRS:
        if d.exists():
            images.extend(
                sorted(p for p in d.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
            )

    rows = []
    agree = 0
    max_diff = 0.0
    for path in images:
        pil = Image.open(path).convert("RGB")
        tensor = preprocess(pil)
        onnx_score = float(np.squeeze(onnx_sess.run(None, {onnx_inp: tensor})[0]))

        feed = np.transpose(tensor, (0, 2, 3, 1)) if nhwc else tensor
        interp.set_tensor(inp_detail["index"], feed)
        interp.invoke()
        tfl_score = float(np.squeeze(interp.get_tensor(out_detail["index"])))

        diff = abs(onnx_score - tfl_score)
        max_diff = max(max_diff, diff)
        o_grade = decode_grade(onnx_score)
        t_grade = decode_grade(tfl_score)
        ok = o_grade == t_grade
        agree += int(ok)
        rows.append(
            {
                "image": path.name,
                "onnx_score": round(onnx_score, 6),
                "tflite_score": round(tfl_score, 6),
                "abs_diff": round(diff, 6),
                "onnx_grade": o_grade,
                "tflite_grade": t_grade,
                "grade_agrees": ok,
            }
        )
        print(
            f"{path.name:45s} onnx={onnx_score:+.4f}(g{o_grade}) "
            f"tflite={tfl_score:+.4f}(g{t_grade}) diff={diff:.5f} {'OK' if ok else 'MISMATCH'}"
        )

    top1 = agree / len(rows) if rows else 0.0
    passed = top1 >= GATE_TOP1_AGREEMENT and max_diff <= GATE_MAX_SCORE_DIFF
    report = {
        "onnx": str(ONNX_PATH.relative_to(ROOT)),
        "tflite": str(TFLITE_PATH.relative_to(ROOT)),
        "input_layout": "NHWC" if nhwc else "NCHW",
        "n_images": len(rows),
        "top1_grade_agreement": round(top1, 4),
        "max_score_abs_diff": round(max_diff, 6),
        "gates": {
            "top1_agreement_min": GATE_TOP1_AGREEMENT,
            "max_score_diff_max": GATE_MAX_SCORE_DIFF,
        },
        "passed": passed,
        "images": rows,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(report, indent=2))
    print(f"\nAgreement {agree}/{len(rows)} = {top1:.2%} | max|diff|={max_diff:.5f}")
    print(f"VERDICT: {'PASSED — ship the fp32 artifact' if passed else 'FAILED — do not ship'}")
    print(f"Saved {OUT_PATH}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
