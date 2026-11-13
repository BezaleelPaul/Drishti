# ============================================================================
# F-5 RETRAIN BUILD — single-cell paste for Kaggle (free GPU)
# ============================================================================
# HOW TO USE:
#   1. kaggle.com -> New Notebook -> Accelerator: GPU T4 or P100
#   2. + Add Input -> search "APTOS 2019 Blindness Detection" -> Add
#   3. Paste this ENTIRE file into one cell -> Run All (~25-40 min on T4)
#   4. Output: /kaggle/working/retrain_f5/final_model_focal.keras
#      -> download it from the notebook's Output panel to your laptop
#   5. MANDATORY GATES back on the laptop (in order), before anything ships:
#        evaluate_calibration.py  (ECE <= 0.10)
#        operating_point_sweep.py --holdout
#        scripts/convert/convert_to_tflite.py --source final_model_focal.keras
#        validate_tflite_quantized.py   (parity vs keras)
#        validate_xai.py                (attention -> evidence re-run)
# ============================================================================
# DEPLOYMENT CONTRACT (identical to the shipped final_model.keras):
#   input:  float32 [N,224,224,3] RAW RGB in 0..255
#   graph:  Rescaling(1/255) -> Normalization -> EfficientNetB0 -> softmax(5)
#   (preprocessing lives INSIDE the graph - the phone app needs zero changes;
#    a passing build swaps in as ONE asset file)
# ============================================================================

import json
import sys
from pathlib import Path

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

DATA_DIR = Path("/kaggle/input/aptos2019-blindness-detection")
OUT_DIR = Path("/kaggle/working/retrain_f5")
INPUT_SIZE, NUM_CLASSES, EPOCHS, BATCH, SEED = 224, 5, 25, 32, 42

print("TF", tf.__version__, "| GPU:", tf.config.list_physical_devices("GPU"))

# ---------------------------------------------------------------- data ----
import csv

rows = []
with open(DATA_DIR / "train.csv", newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        rows.append((row["id_code"], int(row["diagnosis"])))

from PIL import Image

images, labels = [], []
for i, (id_code, label) in enumerate(rows):
    img = Image.open(DATA_DIR / "train_images" / f"{id_code}.png").convert("RGB")
    img = img.resize((INPUT_SIZE, INPUT_SIZE))
    images.append(np.asarray(img, dtype=np.uint8))
    labels.append(label)
    if (i + 1) % 1000 == 0:
        print(f"  loaded {i + 1}/{len(rows)}")
images = np.stack(images)
labels = np.asarray(labels, dtype=np.int32)
print("class counts:", np.bincount(labels, minlength=NUM_CLASSES).tolist())

# ------------------------------------------------- split + oversampling ----
rng = np.random.RandomState(SEED)
train_idx, holdout_idx = [], []
for cls in np.unique(labels):
    idx = np.where(labels == cls)[0]
    rng.shuffle(idx)
    cut = int(len(idx) * 0.15)
    holdout_idx.extend(idx[:cut])
    train_idx.extend(idx[cut:])
train_idx, holdout_idx = np.sort(np.array(train_idx)), np.sort(np.array(holdout_idx))
X_train, y_train = images[train_idx], labels[train_idx]
X_hold, y_hold = images[holdout_idx], labels[holdout_idx]

counts = np.bincount(y_train, minlength=NUM_CLASSES)
total = len(y_train)
target = max(1, int(total * 0.10))
extra = []
for c in range(2, NUM_CLASSES):
    need = target - counts[c]
    if need > 0:
        pool = np.where(y_train == c)[0]
        extra.extend(rng.choice(pool, size=need, replace=True).tolist())
extra = np.array(extra, dtype=np.int64)
if len(extra):
    X_train = np.concatenate([X_train, X_train[extra]])
    y_train = np.concatenate([y_train, y_train[extra]])
perm = rng.permutation(len(X_train))
X_train, y_train = X_train[perm], y_train[perm]
print(f"train={len(X_train)} (after oversample) holdout={len(X_hold)}")

weights = {}
for c in range(NUM_CLASSES):
    w = len(y_train) / (NUM_CLASSES * max(1.0, np.bincount(y_train, minlength=5)[c]))
    weights[c] = round(min(w, 8.0), 3)
print("class weights:", weights)

# ---------------------------------------------------------------- model ----
inputs = layers.Input(shape=(INPUT_SIZE, INPUT_SIZE, 3), dtype=tf.float32)
x = layers.Rescaling(1.0 / 255.0)(inputs)
x = layers.Normalization(axis=3)(x)
base = tf.keras.applications.EfficientNetB0(include_top=False, weights="imagenet", input_tensor=x)
base.trainable = True
y = layers.GlobalAveragePooling2D()(base.output)
y = layers.Dropout(0.25)(y)
outputs = layers.Dense(NUM_CLASSES, activation="softmax")(y)
model = tf.keras.Model(inputs, outputs)

# Adapt the in-graph Normalization to APTOS statistics (dataset-level parity
# with the original artifact's structure).
norm_layer = next(l for l in model.layers if type(l).__name__ == "Normalization")
norm_layer.adapt(X_train[:512].astype(np.float32) / 255.0)
print("Normalization adapted")


# ------------------------------------------------- focal + ordinal loss ----
class FocalLoss(tf.keras.losses.Loss):
    def __init__(self, gamma=2.0, alpha=None, name="focal"):
        super().__init__(name=name)
        self.gamma, self.alpha = gamma, alpha or {}

    def call(self, y_true, y_pred):
        y_true = tf.cast(y_true, tf.int32)
        one_hot = tf.one_hot(y_true, NUM_CLASSES)
        alpha = tf.constant([self.alpha.get(c, 1.0) for c in range(NUM_CLASSES)], dtype=tf.float32)
        p_t = tf.reduce_sum(one_hot * y_pred, axis=-1)
        alpha_t = tf.reduce_sum(one_hot * alpha, axis=-1)
        return tf.reduce_mean(
            alpha_t * tf.pow(1.0 - p_t, self.gamma) * -tf.math.log(tf.clip_by_value(p_t, 1e-8, 1.0))
        )


class FocalOrdinalLoss(FocalLoss):
    """Ordinal cumulative heads ('grade >= k') + focal CE, 50/50:
    the distance penalty aligns with QWK; the focal part fixes the
    majority-class collapse."""

    def call(self, y_true, y_pred):
        y_true = tf.cast(y_true, tf.int32)
        thresholds = tf.range(1, NUM_CLASSES, dtype=tf.int32)
        cum = tf.cast(y_true[:, None] >= thresholds[None, :], tf.float32)
        cum_pred = tf.stack(
            [tf.reduce_sum(y_pred[:, k:], axis=-1) for k in range(1, NUM_CLASSES)],
            axis=-1,
        )
        ord_ce = -tf.reduce_mean(
            cum * tf.math.log(tf.clip_by_value(cum_pred, 1e-8, 1.0))
            + (1.0 - cum) * tf.math.log(tf.clip_by_value(1.0 - cum_pred, 1e-8, 1.0))
        )
        return 0.5 * ord_ce + 0.5 * super().call(y_true, y_pred)


loss_fn = FocalOrdinalLoss(gamma=2.0, alpha=weights)
model.compile(
    optimizer=tf.keras.optimizers.Adam(1e-3),
    loss=lambda yt, yp: loss_fn.call(yt, yp),
    metrics=["accuracy"],
)


# ------------------------------------------------------------- training ----
def augment(img, label):
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
    .batch(BATCH)
    .prefetch(tf.data.AUTOTUNE)
)

history = model.fit(ds, epochs=EPOCHS, verbose=2)

# -------------------------------------------------------------- outputs ----
OUT_DIR.mkdir(parents=True, exist_ok=True)
model.save(str(OUT_DIR / "final_model_focal.keras"))

preds = model.predict(X_hold.astype(np.float32), verbose=0, batch_size=64)
pred_classes = np.argmax(preds, axis=1)
hold_acc = float((pred_classes == y_hold).mean())
hold_sens = float(((pred_classes >= 2) & (y_hold >= 2)).sum() / max(1, int((y_hold >= 2).sum())))
print(f"HOLDOUT top-1: {hold_acc:.4f} | referable-DR recall: {hold_sens:.4f}")
print("(pre-gate sanity only - the REAL gates run on the laptop)")

(OUT_DIR / "training_manifest.json").write_text(
    json.dumps(
        {
            "dataset": "APTOS-2019 (Kaggle)",
            "n_train": int(len(X_train)),
            "n_holdout": int(len(y_hold)),
            "class_weights": {str(k): v for k, v in weights.items()},
            "ordinal": True,
            "focal_gamma": 2.0,
            "epochs": EPOCHS,
            "seed": SEED,
            "final_loss": float(history.history["loss"][-1]),
            "final_accuracy": float(history.history["accuracy"][-1]),
            "holdout_top1": hold_acc,
            "holdout_referable_recall": hold_sens,
            "contract": "float32 [N,224,224,3] raw 0..255 -> softmax(5); preprocessing in-graph",
        },
        indent=2,
    ),
    encoding="utf-8",
)
print("\nDONE -> Output panel: retrain_f5/final_model_focal.keras")
print("Download it, then run the 5 mandatory gates on the laptop before shipping.")
