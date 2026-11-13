"""Evidence run: measure the DRDetect ordinal ONNX model on every clinical
image available in-repo, side by side with the Keras classifier.

This closes the gap flagged in .kiro/specs/claims-evidence-fidelity: the
QWK 0.8931 / sens 99.7% numbers currently have NO committed measurement.
This script records real per-image scores so decisions about shipping
DRDetect rest on evidence, not on a third-party model card.

No labels exist for these images, so QWK/sensitivity cannot be computed
here — raw scores, decoded grades, and Keras-vs-DRDetect agreement are
recorded instead. Usage:
    venv\\Scripts\\python.exe scripts\\convert\\measure_drdetect_evidence.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from src.classification.drdetect_contract import (
    REFERABLE_SCORE_CUT,
    THRESHOLDS,
    preprocess_fundus_to_nchw,
)
from src.classification.ordinal import BASE_SIGMA

ONNX_PATH = ROOT / "models" / "efficientnet_b0_regression_512px.onnx"
KERAS_PATH = ROOT / "final_model.keras"
IMAGE_DIRS = [
    ROOT / "test_samples" / "01_real_clinical_fundus",
    ROOT / "test_samples" / "curated",
]
OUT_PATH = ROOT / "results" / "drdetect_evidence.json"
CLASS_LABELS = ["No DR", "Mild NPDR", "Moderate NPDR", "Severe NPDR", "Proliferative DR"]
SIGMA = BASE_SIGMA


def preprocess_drdetect(pil_img: Image.Image) -> np.ndarray:
    """Canonical contract preprocessing (single source of truth; was a
    byte-for-byte inline port of the classifier path)."""
    return preprocess_fundus_to_nchw(pil_img)


def decode_score(score: float) -> dict:
    grade_val = sum(1 for th in THRESHOLDS if score > th)
    grade_val = min(4, max(0, grade_val))
    dist = min(abs(score - th) for th in THRESHOLDS)
    raw = [float(np.exp(-0.5 * ((c - score) / SIGMA) ** 2)) for c in range(5)]
    total = sum(raw)
    probs = [p / total for p in raw]
    order = np.argsort(probs)[::-1]
    return {
        "score": round(float(score), 6),
        "grade": grade_val,
        "label": CLASS_LABELS[grade_val],
        "referable": bool(score >= REFERABLE_SCORE_CUT),
        "uncertainty": round(float(np.exp(-dist)), 6),
        "probs": [round(p, 6) for p in probs],
        "confidence": round(float(probs[int(order[0])]), 6),
        "margin": round(float(probs[int(order[0])] - probs[int(order[1])]), 6),
    }


def main() -> int:
    if not ONNX_PATH.exists():
        print(f"FAIL: missing {ONNX_PATH}")
        return 1

    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    inp_name = sess.get_inputs()[0].name
    print(f"ONNX input: {sess.get_inputs()[0].shape} {sess.get_inputs()[0].type}")

    keras = None
    if KERAS_PATH.exists():
        import tensorflow as tf

        keras = tf.keras.models.load_model(str(KERAS_PATH), compile=False)
        print("Keras model loaded for comparison")

    images: list[Path] = []
    for d in IMAGE_DIRS:
        if d.exists():
            images.extend(
                sorted(p for p in d.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
            )

    rows = []
    agreements = 0
    for path in images:
        pil = Image.open(path).convert("RGB")
        tensor = preprocess_drdetect(pil)
        out = sess.run(None, {inp_name: tensor})[0]
        score = float(np.squeeze(out))
        row = {"image": path.name, **decode_score(score)}

        if keras is not None:
            kres = keras.predict(
                np.expand_dims(np.asarray(pil.resize((224, 224)), dtype=np.float32), axis=0),
                verbose=0,
            )[0]
            k_grade = int(np.argmax(kres))
            row["keras_grade"] = k_grade
            row["keras_label"] = CLASS_LABELS[k_grade]
            row["keras_top1"] = round(float(kres[k_grade]), 6)
            row["agrees_with_keras"] = k_grade == row["grade"]
            agreements += int(row["agrees_with_keras"])

        rows.append(row)
        print(
            f"{path.name:45s} score={row['score']:+.4f} -> {row['label']:18s} "
            f"conf={row['confidence']:.3f}"
            + (
                f" | keras={row['keras_label']:18s} agree={row['agrees_with_keras']}"
                if keras is not None
                else ""
            )
        )

    summary = {
        "model": str(ONNX_PATH.relative_to(ROOT)),
        "model_backend": "onnx_drdetect",
        "n_images": len(rows),
        "thresholds": THRESHOLDS,
        "keras_comparison": {
            "keras_model": str(KERAS_PATH.relative_to(ROOT)) if keras is not None else None,
            "top1_agreement": round(agreements / len(rows), 4)
            if keras is not None and rows
            else None,
        },
        "grade_distribution": {
            CLASS_LABELS[g]: sum(1 for r in rows if r["grade"] == g) for g in range(5)
        },
        "referable_count": sum(1 for r in rows if r["referable"]),
        "images": rows,
        "notes": (
            "Unlabeled in-repo clinical images: QWK/sensitivity cannot be computed. "
            "Third-party claimed QWK 0.8931 / sens 99.70% remains UNVERIFIED by this repo."
        ),
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(summary, indent=2))
    print(f"\nSaved {OUT_PATH}")
    print(
        f"Grade distribution: {summary['grade_distribution']}  referable={summary['referable_count']}/{len(rows)}"
    )
    if keras is not None:
        print(f"Keras top-1 agreement: {agreements}/{len(rows)} = {agreements / len(rows):.2%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
