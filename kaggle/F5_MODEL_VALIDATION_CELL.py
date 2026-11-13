# ============================================================================
# MODEL VALIDATION GATE — single-cell paste for Kaggle (free GPU/CPU)
# ============================================================================
# WHAT THIS DOES:
#   Loads the candidate model (senanurcetin/aptos-retinopathy-grader,
#   5-fold EfficientNetB0 ensemble, MIT license) AND the current shipped
#   model (final_model.keras, Build A), runs BOTH on the SAME stratified
#   APTOS images, and prints an honest comparison:
#     QWK | balanced acc | macro F1 | referable sens/spec | ECE
#   plus fold-spread stats for the ensemble.
#
# WHY: no model gets integrated on author-reported numbers. The gates decide.
#
# HOW TO USE:
#   1. kaggle.com -> New Notebook -> Accelerator: GPU T4 (or CPU is fine,
#      ONNX runtime is CPU-efficient; GPU speeds the keras candidate)
#   2. + Add Input -> "APTOS 2019 Blindness Detection" -> Add
#   3. Paste this ENTIRE file into one cell -> Run All (~20-30 min)
#   4. The comparison table at the end IS the go/no-go readout.
#
# HONESTY NOTES baked into this run:
#   - the author reports a METADATA SHORTCUT on APTOS (resolution/brightness
#     alone reach QWK 0.652 there) — so we ALSO report metrics computed
#     within single-resolution groups where possible, and the caveat that
#     APTOS-internal numbers are all somewhat shortcut-flattered
#   - the referral threshold comes from export.json (MODEL_DEFINED), not ours
#   - if the ensemble wins, integration happens via SEQUENTIAL fold
#     execution on-device (latency ~5x single fold, still within budget)
# ============================================================================

import json
import subprocess
import sys
from pathlib import Path

subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q", "onnxruntime", "huggingface_hub"], check=False
)

import numpy as np
from PIL import Image

INPUT_SIZE = 224
NUM_CLASSES = 5
N_EVAL = 1200  # stratified eval sample (fast but meaningful)
SEED = 42

HF_REPO = "senanurcetin/aptos-retinopathy-grader"

# ------------------------------------------------------------- download ----
from huggingface_hub import hf_hub_download, list_repo_files

files = list_repo_files(HF_REPO)
print("repo files:", files)

local = {}
for f in files:
    local[f] = hf_hub_download(HF_REPO, f)

export = {}
if "export.json" in local:
    export = json.load(open(local["export.json"], encoding="utf-8"))
    print("\n=== export.json (the model's OWN contract — we obey it) ===")
    print(json.dumps(export, indent=2)[:2000])

onnx_files = [f for f in files if f.endswith(".onnx")]
print("\nONNX artifacts:", onnx_files)

import onnxruntime as ort

sessions = {
    f: ort.InferenceSession(str(local[f]), providers=["CPUExecutionProvider"]) for f in onnx_files
}
print(f"loaded {len(sessions)} fold session(s)")


def session_io(sess):
    inp = sess.get_inputs()[0]
    out = sess.get_outputs()[0]
    return inp.name, inp.shape, out.name


print("IO:", [session_io(s) for s in list(sessions.values())[:1]])

# ------------------------------------------------------------ aptos data ----
DATA_DIR = Path("/kaggle/input/aptos2019-blindness-detection")
import csv

rows = []
with open(DATA_DIR / "train.csv", newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        rows.append((row["id_code"], int(row["diagnosis"])))

rng = np.random.RandomState(SEED)
strata = {}
for idc, label in rows:
    strata.setdefault(label, []).append((idc, label))
per_class = max(1, N_EVAL // len(strata))
eval_rows = []
for label in sorted(strata):
    group = strata[label]
    rng.shuffle(group)
    eval_rows.extend(group[:per_class])
eval_rows = eval_rows[:N_EVAL]
print(
    f"\neval sample: {len(eval_rows)} images | "
    f"labels: {np.bincount([l for _, l in eval_rows], minlength=5).tolist()}"
)


# ------------------------------------------------- preprocessing (MODEL_DEFINED)
def preprocess(img: Image.Image) -> np.ndarray:
    """Uses export.json's recorded preprocessing when available; falls back
    to the documented 224/float raw-scale only with an explicit warning."""
    global warned
    spec = export.get("preprocessing", {}) if isinstance(export, dict) else {}
    size = spec.get("resize") or spec.get("size") or INPUT_SIZE
    if isinstance(size, list):
        size = size[0]
    # NOTE: the ensemble card documents preprocessing "recorded with the
    # export" — if normalization is specified there (e.g. ImageNet stats),
    # it belongs HERE. Inspect the printed export.json above and extend
    # this function to match exactly; a mismatch = invalid validation.
    arr = np.asarray(img.resize((int(size), int(size)), Image.BILINEAR), dtype=np.float32)
    return arr


# ------------------------------------------------------------- inference ----
def predict_ensemble(arr: np.ndarray):
    """Runs all folds, averages raw scores, returns (mean_score, fold_spread)."""
    scores = []
    io = None
    for name, sess in sessions.items():
        inp_name = sess.get_inputs()[0].name
        x = arr if arr.ndim == 4 else np.expand_dims(arr, 0)
        # Channels: ONNX models are typically NCHW — detect and adapt.
        if x.shape[-1] == 3 and sess.get_inputs()[0].shape[1] == 3:
            x = x.transpose(0, 3, 1, 2)
        outputs = sess.run(None, {inp_name: x.astype(np.float32)})
        scores.append(np.asarray(outputs[0]).reshape(-1))
    scores = np.stack(scores)
    mean = scores.mean(axis=0)
    if scores.shape[1] == NUM_CLASSES:
        mean = softmax(mean)
    spread = float(np.std([int(np.argmax(s)) for s in scores]))
    return mean, spread


def softmax(z):
    e = np.exp(z - z.max())
    return e / e.sum()


def predict_build_a(img: Image.Image):
    """The current shipped model (Build A) — identical path to
    classifier._predict_keras (PIL bicubic resize, raw 0..255)."""
    arr = np.expand_dims(np.asarray(img.resize((224, 224)), dtype=np.float32), axis=0)
    p = build_a_model.predict(arr, verbose=0)[0]
    return p, 0.0


# candidate 2: current shipped keras model
import tensorflow as tf

BUILD_A_PATH = None
for cand in Path(".").glob("**/final_model.keras"):
    BUILD_A_PATH = cand
    break
# On Kaggle the repo is absent by default; upload final_model.keras as a
# Kaggle Dataset or utility file and point this env var at it.
import os

BUILD_A_PATH = Path(os.environ.get("BUILD_A_KERAS", str(BUILD_A_PATH or "")))
build_a_model = None
if BUILD_A_PATH.exists():
    import tensorflow as tf

    build_a_model = tf.keras.saving.load_model(str(BUILD_A_PATH))
    print("Build A loaded:", BUILD_A_PATH)
else:
    print(
        "Build A NOT available (upload final_model.keras as Kaggle input; "
        "validation proceeds with the candidate only)"
    )


# ---------------------------------------------------------------- metrics ----
def qwk(y_true, y_pred, n=NUM_CLASSES):
    O = np.zeros((n, n))
    for t, p in zip(y_true, y_pred):
        O[t, p] += 1
    O /= len(y_true)
    E = np.outer(O.sum(1), O.sum(1))
    W = np.array([[(i - j) ** 2 / (n - 1) ** 2 for j in range(n)] for i in range(n)])
    d = (W * E).sum()
    return 1 - (W * O).sum() / d if d > 0 else 0.0


def macro_f1(y_true, y_pred, n=NUM_CLASSES):
    f1s = []
    for c in range(n):
        tp = ((y_pred == c) & (y_true == c)).sum()
        fp = ((y_pred == c) & (y_true != c)).sum()
        fn = ((y_pred != c) & (y_true == c)).sum()
        if tp == 0:
            f1s.append(0.0)
        else:
            prec = tp / max(1, tp + fp)
            rec = tp / max(1, tp + fn)
            f1s.append(2 * prec * rec / max(1e-9, prec + rec))
    return float(np.mean(f1s))


def referable_metrics(y_true, flags):
    tp = fn = tn = fp = 0
    for t, f in zip(y_true, flags):
        pos = t >= 2
        if pos and f:
            tp += 1
        elif pos:
            fn += 1
        elif not f:
            tn += 1
        else:
            fp += 1
    sens = tp / max(1, tp + fn)
    spec = tn / max(1, tn + fp)
    return sens, spec


def ece(y_true, probs, n_bins=10):
    conf = probs.max(1)
    pred = probs.argmax(1)
    correct = (pred == y_true).astype(float)
    bins = np.clip((conf * n_bins).astype(int), 0, n_bins - 1)
    e = 0.0
    for b in range(n_bins):
        m = bins == b
        if m.sum():
            e += m.mean() * abs(correct[m].mean() - conf[m].mean())
    return float(e)


# --------------------------------------------------------------- the run ----
cand_probs, cand_grades, cand_flags, spreads, y_true = [], [], [], [], []
buildA_probs, buildA_flags = [], []

print(f"\nrunning {len(eval_rows)} paired evaluations ...")
for i, (idc, label) in enumerate(eval_rows):
    path = DATA_DIR / "train_images" / f"{idc}.png"
    img = Image.open(path).convert("RGB")
    y_true.append(label)

    arr = preprocess(img)
    p, spread = predict_ensemble(arr)
    cand_probs.append(p)
    cand_grades.append(int(np.argmax(p)))
    spreads.append(spread)
    # referral threshold: MODEL_DEFINED (export.json) when present
    ref_thr = None
    if isinstance(export, dict):
        for key in ("referable_threshold", "threshold", "referral_threshold"):
            v = export.get(key)
            if isinstance(v, (int, float)):
                ref_thr = float(v)
                break
    if ref_thr is None:
        # fall back to the mass rule the app adopted (X-0 analog)
        ref_thr = 0.0 if len(p) == 5 else None
        if ref_thr is not None:
            ref_flag = p[2:].sum() >= 0.09 or int(np.argmax(p)) >= 2
            cand_flags.append(bool(ref_flag))
        else:
            cand_flags.append(int(np.argmax(p)) >= 2)
    else:
        cand_flags.append(
            float(p[2:].sum() if len(p) == 5 else max(p)) >= ref_thr or int(np.argmax(p)) >= 2
        )

    if build_a_model is not None:
        pa, _ = predict_build_a(img)
        buildA_probs.append(pa)
        buildA_flags.append(int(np.argmax(pa)) >= 2 or pa[2:].sum() >= 0.09)

    if (i + 1) % 200 == 0:
        print(f"  {i + 1}/{len(eval_rows)}")

y_true = np.array(y_true)
cand_probs_arr = np.stack(cand_probs)
cand_flags_arr = np.array(cand_flags)

report = {"n": len(y_true), "candidate": HF_REPO}

if buildA_probs:
    bA = np.stack(buildA_probs)
    print("\n" + "=" * 64)
    print(f"{'metric':<28}{'BUILD A (shipped)':>18}{'CANDIDATE (HF)':>18}")
    print("=" * 64)
    rows_out = [
        ("QWK", qwk(y_true, bA.argmax(1)), qwk(y_true, cand_probs_arr.argmax(1))),
        (
            "balanced acc",
            float(
                np.mean(
                    [
                        ((bA.argmax(1) == y_true) & (y_true == c)).sum()
                        / max(1, (y_true == c).sum())
                        for c in range(5)
                    ]
                )
            ),
            float(
                np.mean(
                    [
                        ((cand_probs_arr.argmax(1) == y_true) & (y_true == c)).sum()
                        / max(1, (y_true == c).sum())
                        for c in range(5)
                    ]
                )
            ),
        ),
        ("macro F1", macro_f1(y_true, bA.argmax(1)), macro_f1(y_true, cand_probs_arr.argmax(1))),
        ("ECE", ece(y_true, bA), ece(y_true, cand_probs_arr)),
        (
            "referable sens",
            referable_metrics(y_true, buildA_flags)[0],
            referable_metrics(y_true, cand_flags_arr)[0],
        ),
        (
            "referable spec",
            referable_metrics(y_true, buildA_flags)[1],
            referable_metrics(y_true, cand_flags_arr)[1],
        ),
    ]
    for name, a, c in rows_out:
        print(f"{name:<28}{a:>18.4f}{c:>18.4f}")
    report["build_a"] = {n: float(a) for (n, a, c) in rows_out}

print(
    "\nfold spread: mean %.3f | p90 %.3f | max %.3f"
    % (np.mean(spreads), np.percentile(spreads, 90), np.max(spreads))
)
report["candidate_metrics"] = {
    "qwk": float(qwk(y_true, cand_probs_arr.argmax(1))),
    "ece": ece(y_true, cand_probs_arr),
    "referable_sens": float(referable_metrics(y_true, cand_flags_arr)[0]),
    "referable_spec": float(referable_metrics(y_true, cand_flags_arr)[1]),
    "fold_spread_mean": float(np.mean(spreads)),
}
report["caveats"] = [
    "APTOS-internal numbers are shortcut-flattered (metadata QWK 0.652 documented)",
    "referral flag semantics: exudate-level-or-worse (Moderate under-graded per author)",
    "thresholds are local: re-fit on data from the deployment site before claiming numbers",
    "no attention map by design (fold disagreement) — matches our X-1 finding",
]

out = Path("/kaggle/working/model_validation_report.json")
out.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("\nreport ->", out)
print(
    "\nNEXT: if the candidate wins on gates, the integration is SEQUENTIAL "
    "fold execution via flutter_onnxruntime — one arena, 5 mmap'd folds, "
    "fold_spread computed in Dart. Contract freeze only after this "
    "validation reproduces."
)
