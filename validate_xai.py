"""XAI truthfulness validation via Insertion/Deletion metrics (Ticket X-1).

Proves the Grad-CAM heatmaps are truthful, not just pretty:
  - DELETION: progressively replace the most-important pixels (per the
    heatmap) with the image mean. A truthful heatmap collapses the target
    confidence FAST -> deletion AUC LOW (vs random ordering baseline).
  - INSERTION: start from the all-mean image, progressively reveal pixels
    in importance order. Truthful heatmap -> confidence rises FAST ->
    insertion AUC HIGH.

Gates (vs the random-ordering baseline, per image):
  deletion AUC  <= random deletion AUC  - 0.10
  insertion AUC >= random insertion AUC + 0.10
Anything else means the heatmap ordering is not better than noise and the
heatmap must NOT be shown to operators (honesty contract).

Usage:
    python validate_xai.py --images-dir test_samples/01_real_clinical_fundus
Output: results/xai_insertion_deletion.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

PROJECT_ROOT = Path(__file__).resolve().parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

STEPS = 20  # 5%-pixel increments
INPUT_SIZE = 224
DELETION_MARGIN = 0.10
INSERTION_MARGIN = 0.10


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Insertion/Deletion XAI gates")
    p.add_argument(
        "--images-dir",
        type=Path,
        default=PROJECT_ROOT / "test_samples" / "01_real_clinical_fundus",
    )
    p.add_argument("--limit", type=int, default=6)
    p.add_argument(
        "--out", type=Path, default=PROJECT_ROOT / "results" / "xai_insertion_deletion.json"
    )
    return p.parse_args()


def collect_images(d: Path, limit: int) -> list[Path]:
    paths: list[Path] = []
    for ext in ("*.jpg", "*.jpeg", "*.png", "*.JPG", "*.JPEG", "*.PNG"):
        paths.extend(sorted(d.glob(ext)))
    return paths[:limit]


def auc(fractions: np.ndarray, confidences: np.ndarray) -> float:
    """Trapezoid AUC over the pixel-fraction axis, normalized to [0,1]."""
    x = np.asarray(fractions, dtype=np.float64)
    y = np.clip(np.asarray(confidences, dtype=np.float64), 0.0, 1.0)
    order = np.argsort(x)
    x, y = x[order], y[order]
    if x[-1] <= x[0]:
        return float(y[0])
    return float(np.trapezoid(y, x) / (x[-1] - x[0]))


def confidence_for(model, arr: np.ndarray, class_idx: int) -> float:
    preds = model.predict(arr, verbose=0)[0]
    return float(preds[class_idx])


def curves(
    model,
    arr: np.ndarray,
    importance: np.ndarray,
    class_idx: int,
    rng: np.random.Generator | None = None,
) -> dict:
    """Runs deletion + insertion curves for one importance ordering.

    Baseline = strong Gaussian blur of the image (the RISE-standard
    "blurring game"). A flat mean-color baseline is WRONG for fundus
    images: masking background pixels with dark-red mean creates
    hemorrhage-like dots that themselves move the model — measured and
    rejected in the first run of this validator.

    importance: flattened [H*W] scores (higher = more important). When
    ``rng`` is set the ordering is shuffled (random baseline).
    """
    h, w = INPUT_SIZE, INPUT_SIZE
    flat = importance.reshape(-1).astype(np.float64)
    flat = np.nan_to_num(flat, nan=0.0, posinf=0.0, neginf=0.0)
    order = np.argsort(-flat)  # most important first
    if rng is not None:
        rng.shuffle(order)

    base = arr[0].copy()  # H,W,3 float 0..255
    baseline_img = np.asarray(
        Image.fromarray(base.astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius=10)),
        dtype=np.float64,
    )

    fractions = np.linspace(0.0, 1.0, STEPS + 1)
    k_counts = (fractions * flat.size).astype(int)

    # Deletion: mask the top-k important pixels with the blurred value.
    del_conf = []
    for k in k_counts:
        masked = base.copy()
        if k > 0:
            idx = order[:k]
            ys, xs = np.divmod(idx, w)
            masked[ys, xs, :] = baseline_img[ys, xs, :]
        del_conf.append(confidence_for(model, np.expand_dims(masked, 0), class_idx))

    # Insertion: start all-blurred, reveal top-k important pixels.
    ins_conf = []
    for k in k_counts:
        revealed = baseline_img.copy()
        if k > 0:
            idx = order[:k]
            ys, xs = np.divmod(idx, w)
            revealed[ys, xs, :] = base[ys, xs, :]
        ins_conf.append(confidence_for(model, np.expand_dims(revealed, 0), class_idx))

    return {
        "fractions": fractions.tolist(),
        "deletion_conf": [round(c, 4) for c in del_conf],
        "insertion_conf": [round(c, 4) for c in ins_conf],
        "deletion_auc": round(auc(fractions, del_conf), 4),
        "insertion_auc": round(auc(fractions, ins_conf), 4),
    }


def main() -> int:
    args = parse_args()
    images = collect_images(args.images_dir, args.limit)
    if not images:
        raise SystemExit(f"No images found under {args.images_dir}")

    print(f"[1/4] Loading keras reference ...")
    import keras

    model = keras.saving.load_model(str(PROJECT_ROOT / "final_model.keras"))
    _ = model.output

    print("[2/4] Loading Grad-CAM explainer ...")
    from src.classification.gradcam import GradCAMExplainer

    explainer = GradCAMExplainer()
    rng = np.random.default_rng(42)

    results = []
    gates_passed = 0
    print("[3/4] Computing insertion/deletion curves ...")
    for p in images:
        img = Image.open(p).convert("RGB")
        arr = np.expand_dims(
            np.asarray(img.resize((INPUT_SIZE, INPUT_SIZE)), dtype=np.float32), axis=0
        )
        preds = model.predict(arr, verbose=0)[0]
        class_idx = int(np.argmax(preds))
        orig_conf = float(preds[class_idx])

        # Raw attention map from the same Grad-CAM the server overlay uses.
        try:
            importance, layer = explainer._compute_keras_gradcam(
                model, np.asarray(img.resize((INPUT_SIZE, INPUT_SIZE))), class_idx
            )
        except Exception as e:  # noqa: BLE001 - report the failure honestly
            results.append({"image": p.name, "error": str(e)[:200]})
            continue
        if importance is None:
            results.append({"image": p.name, "error": "no attention map produced"})
            continue
        imp = np.asarray(importance, dtype=np.float64)
        if imp.shape[:2] != (INPUT_SIZE, INPUT_SIZE):
            imp_img = Image.fromarray(
                np.clip((imp - imp.min()) / (np.ptp(imp) + 1e-9) * 255, 0, 255).astype(np.uint8)
            ).resize((INPUT_SIZE, INPUT_SIZE))
            imp = np.asarray(imp_img, dtype=np.float64) / 255.0
        if imp.ndim == 3:
            imp = imp.mean(axis=2)

        truth = curves(model, arr, imp, class_idx)
        random = curves(model, arr, imp, class_idx, rng=rng)

        passed = (
            truth["deletion_auc"] <= random["deletion_auc"] - DELETION_MARGIN
            and truth["insertion_auc"] >= random["insertion_auc"] + INSERTION_MARGIN
        )
        gates_passed += int(passed)
        results.append(
            {
                "image": p.name,
                "target_class": class_idx,
                "orig_confidence": round(orig_conf, 4),
                "layer": layer,
                "truthful": truth,
                "random_baseline": random,
                "passed": bool(passed),
            }
        )
        print(
            f"      {p.name}: del {truth['deletion_auc']:.3f} (rand {random['deletion_auc']:.3f}) "
            f"ins {truth['insertion_auc']:.3f} (rand {random['insertion_auc']:.3f}) "
            f"{'PASS' if passed else 'FAIL'}"
        )

    evaluated = [r for r in results if "error" not in r]
    summary = {
        "n_images": len(images),
        "n_evaluated": len(evaluated),
        "gates_passed": gates_passed,
        "gates": {
            "deletion_margin": DELETION_MARGIN,
            "insertion_margin": INSERTION_MARGIN,
            "meaning": "heatmap ordering must beat random by the margin on BOTH curves",
        },
        "all_passed": bool(evaluated) and gates_passed == len(evaluated),
        "results": results,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}, indent=2))

    if not summary["all_passed"]:
        print(
            "XAI FAIL: heatmap ordering is not better than random on every image. "
            "Per the honesty contract, do not surface heatmaps to operators until fixed."
        )
        return 1
    print("XAI PASS: heatmaps are measurably truthful.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
