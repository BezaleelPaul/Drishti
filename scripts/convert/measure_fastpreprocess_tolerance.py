"""Measured tolerance for the on-device fast preprocessing path.

Python production pipeline (classifier.py): circle-crop at NATIVE resolution
-> Ben Graham Gaussian sigma=20 at native res -> INTER_AREA resize to 512.

On-device Dart cannot afford a 121-tap Gaussian at multi-megapixel
resolution. Candidate fast path: INTER_AREA downscale to a fixed working
size first, then Gaussian with sigma scaled by (working/native), then
resize to 512. This script MEASURES the score drift of the fast path
against the exact path on every clinical image in-repo and records the
result as a documented tolerance (never silently assumed).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ONNX_PATH = ROOT / "models" / "efficientnet_b0_regression_512px.onnx"
IMAGE_DIRS = [
    ROOT / "test_samples" / "01_real_clinical_fundus",
    ROOT / "test_samples" / "curated",
]
OUT_PATH = ROOT / "results" / "drdetect_fastpreprocess_tolerance.json"
WORKING_SIZE = 768
sys.path.insert(0, str(ROOT))
from src.classification.drdetect_contract import THRESHOLDS


def base_crop(pil_img: Image.Image) -> np.ndarray:
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
    return cv2.bitwise_and(cropped, cropped, mask=circ_mask)[
        cy - radius : cy + radius, cx - radius : cx + radius
    ]


def finish(circled: np.ndarray) -> np.ndarray:
    resized = cv2.resize(circled, (512, 512), interpolation=cv2.INTER_AREA)
    norm_01 = resized.astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    return np.transpose((norm_01 - mean) / std, (2, 0, 1))[None].astype(np.float32)


def exact(circled: np.ndarray) -> np.ndarray:
    blurred = cv2.GaussianBlur(circled, (0, 0), 20)
    return finish(cv2.addWeighted(circled, 4, blurred, -4, 128))


def fast(circled: np.ndarray, native: int) -> np.ndarray:
    h, w = circled.shape[:2]
    scale = WORKING_SIZE / max(h, w)
    if max(h, w) > WORKING_SIZE:
        work = cv2.resize(circled, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    else:
        work = circled
    sigma = 20.0 * (work.shape[0] / h)
    blurred = cv2.GaussianBlur(work, (0, 0), sigma)
    return finish(cv2.addWeighted(work, 4, blurred, -4, 128))


def grade(score: float) -> int:
    return min(4, max(0, sum(1 for th in THRESHOLDS if score > th)))


def main() -> int:
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name

    images: list[Path] = []
    for d in IMAGE_DIRS:
        if d.exists():
            images.extend(
                sorted(p for p in d.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
            )

    rows = []
    max_drift = 0.0
    agree = 0
    for path in images:
        circled = base_crop(Image.open(path).convert("RGB"))
        native = circled.shape[0]
        s_exact = float(np.squeeze(sess.run(None, {name: exact(circled)})[0]))
        s_fast = float(np.squeeze(sess.run(None, {name: fast(circled, native)})[0]))
        drift = abs(s_exact - s_fast)
        max_drift = max(max_drift, drift)
        ok = grade(s_exact) == grade(s_fast)
        agree += int(ok)
        rows.append(
            {
                "image": path.name,
                "native_side": int(native),
                "score_exact": round(s_exact, 6),
                "score_fast": round(s_fast, 6),
                "drift": round(drift, 6),
                "grade_agrees": ok,
            }
        )
        print(
            f"{path.name:45s} native={native:4d} exact={s_exact:+.4f}(g{grade(s_exact)}) fast={s_fast:+.4f}(g{grade(s_fast)}) drift={drift:.4f} {'OK' if ok else 'MISMATCH'}"
        )

    report = {
        "working_size": WORKING_SIZE,
        "n_images": len(rows),
        "max_score_drift": round(max_drift, 6),
        "grade_agreement": round(agree / len(rows), 4) if rows else 0.0,
        "recommended_dart_tolerance": round(max(max_drift * 2, 0.02), 4),
        "images": rows,
    }
    OUT_PATH.write_text(json.dumps(report, indent=2))
    print(f"\nMax drift {max_drift:.4f} | grade agreement {agree}/{len(rows)}")
    print(f"Recommended Dart preprocessing score tolerance: {report['recommended_dart_tolerance']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
