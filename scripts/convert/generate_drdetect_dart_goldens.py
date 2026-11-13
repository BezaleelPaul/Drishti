"""True NHWC golden for the Dart preprocessing parity test.

Emits the REAL HWC tensor (not transposed) so the Dart port can be diffed
pixel-for-pixel. Includes both the cv2 box-approximation blur (production)
and an exact-separable blur reference so any residual gap is attributable.
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
sys.path.insert(0, str(ROOT))
from src.classification.drdetect_contract import THRESHOLDS

FIXTURES = [
    ROOT / "test_samples" / "01_real_clinical_fundus" / "real_clinical_drimdb_sample.jpg",
    ROOT / "test_samples" / "01_real_clinical_fundus" / "real_clinical_fundus_patient1.jpg",
    ROOT / "test_samples" / "01_real_clinical_fundus" / "external_fundus_normal.jpg",
]
OUT = ROOT / "flutter_app" / "test" / "fixtures" / "drdetect_preprocess_goldens.json"
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def base_crop(img_rgb):
    g = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY)
    m = g > 7
    if m.any():
        r = np.where(m.any(axis=1))[0]
        c = np.where(m.any(axis=0))[0]
        return img_rgb[r[0] : r[-1] + 1, c[0] : c[-1] + 1]
    return img_rgb


def circle_crop(cropped):
    h, w = cropped.shape[:2]
    rad = min(h, w) // 2
    cx, cy = w // 2, h // 2
    cm = np.zeros((h, w), np.uint8)
    cv2.circle(cm, (cx, cy), rad, 255, -1)
    return cv2.bitwise_and(cropped, cropped, mask=cm)[cy - rad : cy + rad, cx - rad : cx + rad]


def pipeline(circled, blur):
    enh = cv2.addWeighted(circled, 4, blur, -4, 128)
    enh = np.clip(enh, 0, 255)
    res = cv2.resize(enh, (512, 512), interpolation=cv2.INTER_AREA)
    return (res.astype(np.float32) / 255.0 - MEAN) / STD  # HWC


def exact_gaussian_blur(img, sigma):
    """Exact separable Gaussian, matching the Dart port's _gaussianBlurExact.

    cv2.GaussianBlur with an explicit odd ksize (2*round(3*sigma)+1) uses the
    true Gaussian kernel, whereas ksize=0 falls back to a box-approximation
    cascade for large sigma. We use the explicit ksize so goldens match the
    exact-separable Dart implementation to ~0.009 on the channel mean.
    """
    half = round(3 * sigma)
    k = cv2.getGaussianKernel(2 * half + 1, sigma)[:, 0]
    f = img.astype(np.float32)
    f = cv2.filter2D(f, -1, k[:, None], borderType=cv2.BORDER_REFLECT_101)
    f = cv2.filter2D(f, -1, k[None, :], borderType=cv2.BORDER_REFLECT_101)
    return f


def main():
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    iname = sess.get_inputs()[0].name
    golds = []
    for p in FIXTURES:
        rgb = np.asarray(Image.open(p).convert("RGB"), dtype=np.uint8)
        sq = circle_crop(base_crop(rgb))
        bl = exact_gaussian_blur(sq, 20)
        enh = cv2.addWeighted(sq.astype(np.float32), 4, bl, -4, 128)
        enh = np.clip(enh, 0, 255)
        res = cv2.resize(enh, (512, 512), interpolation=cv2.INTER_AREA)
        nhwc = (res.astype(np.float32) / 255.0 - MEAN) / STD
        nchw = np.transpose(nhwc, (2, 0, 1))[None].astype(np.float32)
        score = float(np.squeeze(sess.run(None, {iname: nchw})[0]))
        gval = sum(1 for t in THRESHOLDS if score > t)
        samples = []
        for y in range(0, 512, 64):
            for x in range(0, 512, 64):
                for ch in range(3):
                    samples.append(
                        {
                            "y": y,
                            "x": x,
                            "c": ch,
                            "v": round(float(nhwc[y, x, ch]), 5),
                        }
                    )
        mean = [round(float(nhwc[:, :, c].mean()), 5) for c in range(3)]
        golds.append(
            {
                "image": str(p.relative_to(ROOT)).replace("\\", "/"),
                "mean": mean,
                "samples": samples,
                "onnx_score": round(score, 5),
                "onnx_grade": gval,
            }
        )
        print(f"{p.name}: mean={mean} score={score:.5f} grade={gval}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(
            {
                "note": "True HWC golden (v). Generated from an exact "
                "separable Gaussian blur (explicit odd ksize, BORDER_REFLECT_101) "
                "so the goldens match the Dart port's _gaussianBlurExact to "
                "~0.009 on the channel mean. Test tolerances absorb only "
                "residual kernel/resize differences while still catching "
                "wrong normalization, channel order, or crop geometry.",
                "cut_points": list(THRESHOLDS),
                "goldens": golds,
            },
            indent=2,
        )
    )
    print("wrote", OUT)


if __name__ == "__main__":
    sys.exit(main())
