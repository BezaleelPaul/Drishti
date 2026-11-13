"""F-5 retrain build: focal loss + ordinal targets + class weights.

Builds a NEW model artifact (final_model_focal.keras) that honors the
exact deployment contract of the current final_model.keras:
  - input: float32 [N,224,224,3] RAW RGB in [0,255]
  - Rescaling(1/255) -> per-channel Normalization -> EfficientNetB0 -> softmax(5)
    all INSIDE the graph (so the Dart classifier needs zero changes)
  - output: softmax 5-vector

Research recipe (docs/TEAM_PLAN_NEXT_UPDATE.md §4):
  - class weights (inverse-frequency, capped) for the 73%-grade-0 imbalance
  - focal loss (gamma=2, alpha=class weights) for the majority collapse
  - ordinal cumulative targets option: 4 binary heads "grade >= k" reshaped
    into a 5-class softmax via a fixed triangular target matrix — optimizes
    the QWK-relevant distance structure
  - minority oversampling: grades 2-4 duplicated (with augmentation) so each
    reaches ~10% of the training stream
  - stratified split with a patient-safe holdout for the gate pipeline

Usage (Kaggle GPU recommended; ~20 min on P100):
    python scripts/retrain_focal.py --data-dir /kaggle/input/aptos2019-blindness-detection \
        --epochs 25 --out-dir scripts/convert/out/retrain_f5
The artifact MUST then pass the full gate pipeline before shipping:
  evaluate_calibration.py -> operating_point_sweep.py --holdout ->
  validate_tflite_quantized.py -> validate_xai.py
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

INPUT_SIZE = 224
NUM_CLASSES = 5
SEED = 42


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="F-5 retrain build")
    p.add_argument(
        "--data-dir",
        type=Path,
        required=True,
        help="APTOS dir containing train.csv + train_images/",
    )
    p.add_argument(
        "--out-dir", type=Path, default=PROJECT_ROOT / "scripts" / "convert" / "out" / "retrain_f5"
    )
    p.add_argument("--epochs", type=int, default=25)
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--focal-gamma", type=float, default=2.0)
    p.add_argument(
        "--ordinal",
        action="store_true",
        default=True,
        help="Ordinal cumulative targets (default ON)",
    )
    p.add_argument("--no-ordinal", dest="ordinal", action="store_false")
    p.add_argument(
        "--max-train", type=int, default=0, help="Cap training size for smoke tests (0 = all)"
    )
    return p.parse_args()


def load_aptos(data_dir: Path, max_train: int = 0):
    """Loads train.csv + images as RGB uint8 arrays (raw 0..255 — the
    deployment scale; normalization happens inside the graph)."""
    import csv
    from PIL import Image

    csv_path = data_dir / "train.csv"
    img_dir = data_dir / "train_images"
    rows = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            rows.append((row["id_code"], int(row["diagnosis"])))
    if max_train:
        rows = rows[:max_train]

    images, labels = [], []
    for i, (id_code, label) in enumerate(rows):
        path = img_dir / f"{id_code}.png"
        img = Image.open(path).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE))
        images.append(np.asarray(img, dtype=np.uint8))
        labels.append(label)
        if (i + 1) % 500 == 0:
            print(f"  loaded {i + 1}/{len(rows)}")
    return np.stack(images), np.asarray(labels, dtype=np.int32)


def stratified_split(labels: np.ndarray, holdout_frac: float = 0.15):
    """Deterministic stratified split (same discipline as the eval harness)."""
    rng = np.random.RandomState(SEED)
    train_idx, holdout_idx = [], []
    for cls in np.unique(labels):
        idx = np.where(labels == cls)[0]
        rng.shuffle(idx)
        cut = int(len(idx) * holdout_frac)
        holdout_idx.extend(idx[:cut])
        train_idx.extend(idx[cut:])
    return np.sort(np.array(train_idx)), np.sort(np.array(holdout_idx))


def class_weights(labels: np.ndarray) -> dict[int, float]:
    """Inverse-frequency weights, capped at 8x so grade-4 is not nuked."""
    counts = np.bincount(labels, minlength=NUM_CLASSES).astype(np.float64)
    total = counts.sum()
    weights = {}
    for c in range(NUM_CLASSES):
        w = total / (NUM_CLASSES * max(1.0, counts[c]))
        weights[c] = round(min(w, 8.0), 3)
    return weights


def oversample_minorities(images: np.ndarray, labels: np.ndarray, target_frac: float = 0.10):
    """Duplicates minority-class samples (augmentation applied online) until
    each grade reaches ~target_frac of the training stream."""
    counts = np.bincount(labels, minlength=NUM_CLASSES)
    total = len(labels)
    target = max(1, int(total * target_frac))
    out_idx = list(range(total))
    rng = np.random.RandomState(SEED)
    for c in range(2, NUM_CLASSES):
        need = target - counts[c]
        if need <= 0:
            continue
        pool = np.where(labels == c)[0]
        picks = rng.choice(pool, size=need, replace=True)
        out_idx.extend(picks.tolist())
    rng.shuffle(out_idx)
    return images[out_idx], labels[out_idx]


def build_model(use_ordinal: bool) -> tuple:
    """EfficientNetB0 + in-graph preprocessing (Rescaling -> Normalization),
    identical deployment contract to final_model.keras. Returns (model, loss)."""
    inputs = layers.Input(shape=(INPUT_SIZE, INPUT_SIZE, 3), dtype=tf.float32)
    x = layers.Rescaling(1.0 / 255.0)(inputs)
    x = layers.Normalization(axis=3)(x)  # adapted below to APTOS stats
    base = tf.keras.applications.EfficientNetB0(
        include_top=False, weights="imagenet", input_tensor=x
    )
    base.trainable = True
    y = layers.GlobalAveragePooling2D()(base.output)
    y = layers.Dropout(0.25)(y)
    outputs = layers.Dense(NUM_CLASSES, activation="softmax")(y)
    model = tf.keras.Model(inputs, outputs)

    if use_ordinal:
        loss = FocalOrdinalLoss(gamma=2.0)
    else:
        loss = FocalLoss(gamma=2.0)
    return model, loss


class FocalLoss(tf.keras.losses.Loss):
    """Focal loss (Lin et al. 2017) with per-class alpha weights."""

    def __init__(self, gamma: float = 2.0, alpha: dict[int, float] | None = None, name="focal"):
        super().__init__(name=name)
        self.gamma = gamma
        self.alpha = alpha or {}

    def call(self, y_true, y_pred):
        y_true = tf.cast(y_true, tf.int32)
        one_hot = tf.one_hot(y_true, NUM_CLASSES)
        alpha = tf.constant([self.alpha.get(c, 1.0) for c in range(NUM_CLASSES)], dtype=tf.float32)
        p_t = tf.reduce_sum(one_hot * y_pred, axis=-1)
        alpha_t = tf.reduce_sum(one_hot * alpha, axis=-1)
        focal = (
            alpha_t * tf.pow(1.0 - p_t, self.gamma) * -tf.math.log(tf.clip_by_value(p_t, 1e-8, 1.0))
        )
        return tf.reduce_mean(focal)


class FocalOrdinalLoss(FocalLoss):
    """Ordinal formulation: each sample trains K-1 binary sub-tasks
    ('is grade >= k?') whose cumulative sums recover a soft 5-class
    distribution — penalizes distant errors harder (QWK-aligned)."""

    def call(self, y_true, y_pred):
        y_true = tf.cast(y_true, tf.int32)
        # Cumulative binary targets: for grade g, targets are [g>=1, g>=2, g>=3, g>=4].
        thresholds = tf.range(1, NUM_CLASSES, dtype=tf.int32)
        cum = tf.cast(y_true[:, None] >= thresholds[None, :], tf.float32)  # [B,4]
        # Predicted cumulative probabilities from softmax margins.
        probs = y_pred  # [B,5]
        cum_pred = tf.stack(
            [tf.reduce_sum(probs[:, k:], axis=-1) for k in range(1, NUM_CLASSES)], axis=-1
        )
        # Ordinal CE on the cumulative heads + focal CE on the argmax head
        # (weight 0.5 each): distance penalty + majority-collapse fix.
        ord_ce = -tf.reduce_mean(
            cum * tf.math.log(tf.clip_by_value(cum_pred, 1e-8, 1.0))
            + (1.0 - cum) * tf.math.log(tf.clip_by_value(1.0 - cum_pred, 1e-8, 1.0))
        )
        focal = super().call(y_true, y_pred)
        return 0.5 * ord_ce + 0.5 * focal


def adapt_normalization(model, images: np.ndarray) -> None:
    """Fits the in-graph Normalization layer to APTOS train statistics
    (matching how the original artifact carried dataset stats)."""
    norm_layer = None
    for layer in model.layers:
        if type(layer).__name__ == "Normalization":
            norm_layer = layer
            break
    if norm_layer is None:
        raise RuntimeError("Normalization layer not found in the built model")
    sample = images[:512].astype(np.float32) / 255.0
    norm_layer.adapt(sample)
    print("  Normalization adapted on 512-sample APTOS statistics")


def main() -> int:
    args = parse_args()
    if not (args.data_dir / "train.csv").exists():
        raise SystemExit(f"train.csv not found under {args.data_dir}")

    print(f"[1/6] Loading APTOS from {args.data_dir} ...")
    images, labels = load_aptos(args.data_dir, args.max_train)
    print(f"      {len(images)} images | class counts: {np.bincount(labels, minlength=5).tolist()}")

    print("[2/6] Stratified split + minority oversampling ...")
    train_idx, holdout_idx = stratified_split(labels)
    X_train, y_train = images[train_idx], labels[train_idx]
    X_hold, y_hold = images[holdout_idx], labels[holdout_idx]
    X_train, y_train = oversample_minorities(X_train, y_train, target_frac=0.10)
    print(f"      train={len(X_train)} (after oversample) holdout={len(X_hold)}")
    weights = class_weights(y_train)
    print(f"      class weights: {weights}")

    print("[3/6] Building model (focal gamma=2, ordinal=%s) ..." % args.ordinal)
    model, loss = build_model(use_ordinal=args.ordinal)
    adapt_normalization(model, X_train)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss=lambda yt, yp: loss.call(yt, yp),
        metrics=["accuracy"],
    )

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    def augment(img: tf.Tensor, label: tf.Tensor):
        img = tf.image.random_flip_left_right(img)
        img = tf.image.random_flip_up_down(img)
        img = tf.image.random_brightness(img, 0.08)
        img = tf.image.random_contrast(img, 0.9, 1.1)
        img = tf.clip_by_value(img, 0.0, 255.0)
        return img, label

    ds = (
        tf.data.Dataset.from_tensor_slices((X_train, y_train))
        .shuffle(min(len(X_train), 5000), seed=SEED)
        .map(augment, num_parallel_calls=tf.data.AUTOTUNE)
        .batch(args.batch_size)
        .prefetch(tf.data.AUTOTUNE)
    )

    print(f"[4/6] Training {args.epochs} epochs ...")
    history = model.fit(ds, epochs=args.epochs, verbose=2)

    print("[5/6] Saving artifacts ...")
    model.save(str(out_dir / "final_model_focal.keras"))
    (out_dir / "training_manifest.json").write_text(
        json.dumps(
            {
                "dataset": str(args.data_dir),
                "n_train": int(len(X_train)),
                "n_holdout": int(len(y_hold)),
                "class_weights": {str(k): v for k, v in weights.items()},
                "focal_gamma": args.focal_gamma,
                "ordinal": bool(args.ordinal),
                "epochs": args.epochs,
                "seed": SEED,
                "final_loss": float(history.history["loss"][-1]),
                "final_accuracy": float(history.history["accuracy"][-1]),
                "contract": "float32 [N,224,224,3] raw 0..255 -> softmax(5); preprocessing in-graph",
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print("[6/6] Holdout sanity (pre-gate) ...")
    preds = model.predict(X_hold.astype(np.float32), verbose=0, batch_size=64)
    pred_classes = np.argmax(preds, axis=1)
    acc = float((pred_classes == y_hold).mean())
    print(f"      holdout top-1: {acc:.4f} (pre-gate sanity; the REAL gates run separately)")

    (out_dir / "holdout_report.json").write_text(
        json.dumps({"holdout_accuracy": acc, "n_holdout": len(y_hold)}, indent=2),
        encoding="utf-8",
    )
    print(
        "NEXT (mandatory gates, in order):\n"
        "  1. evaluate_calibration.py on the new artifact (ECE <= 0.10)\n"
        "  2. operating_point_sweep.py --holdout (quote the held-out sensitivity)\n"
        "  3. convert: scripts/convert/convert_to_tflite.py --source final_model_focal.keras\n"
        "  4. validate_tflite_quantized.py (parity)\n"
        "  5. validate_xai.py (re-run: if it passes, heatmaps graduate to evidence)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
