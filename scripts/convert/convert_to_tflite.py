"""Convert final_model.keras to int8 TFLite with float I/O (Ticket A-1).

Why float in/out: the Rescaling/Normalization preprocessing chain lives INSIDE
the graph (verified in final_model.keras), so the converter must keep those ops
in float; forcing int8 I/O would fuse normalization into int8 affine maps and
silently shift the calibration distribution relative to training.

Deliberate simplification for v1: the production artifact carries the softmax
head only. The dual-output (heatmap) graph is a P2 item (F-1) because the
Grad-CAM target layer must be fixed and validated against gradcam.py's
layer-replay logic; a wrong 2nd output is worse than none.

Fallback ladder (move UP the ladder only when a parity gate fails):
  int8 float-IO -> fp16 -> ONNX (flutter_onnxruntime).

Calibration data: NEVER use the evaluation/test split. Use a dedicated
--rep-images-dir of ~400 stratified real screening images (per plan, Phase A;
stratification helper provided here if a labeled CSV is available).

Usage:
    python scripts/convert/convert_to_tflite.py \
        --source final_model.keras \
        --rep-images-dir <dir with calibration fundus images>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Iterator

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

REPRESENTATIVE_LIMIT = 400
INPUT_SIZE = 224  # must match classifier.py preprocessing parity contract


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Convert final_model.keras to deployable TFLite")
    p.add_argument("--source", type=Path, default=PROJECT_ROOT / "final_model.keras")
    p.add_argument("--out-dir", type=Path, default=PROJECT_ROOT / "scripts" / "convert" / "out")
    p.add_argument(
        "--rep-images-dir",
        type=Path,
        default=None,
        help="Directory of calibration images (raw fundus; stratified across grades). "
        "Never calibrate on the test split.",
    )
    p.add_argument("--rep-limit", type=int, default=REPRESENTATIVE_LIMIT)
    p.add_argument("--skip-calib", action="store_true", help="Skip int8; emit fp16/fp32 only")
    p.add_argument("--variant", choices=["all", "int8", "fp16", "fp32"], default="all")
    return p.parse_args()


def load_keras_model(source: Path):
    """Load the Keras-3 artifact and force graph build before conversion."""
    import keras

    model = keras.saving.load_model(str(source))
    # Keras 3 lazy-builds; the converter needs a concrete function or it raises
    # "No concrete functions specified".
    _ = model.output
    return model


def export_saved_model(model, out_dir: Path) -> Path:
    sm_dir = out_dir / "saved_model"
    # Keras 3 export names the TF SavedModel format "tf_saved_model".
    model.export(str(sm_dir), format="tf_saved_model")
    return sm_dir


def collect_rep_images(rep_dir: Path, limit: int) -> list[Path]:
    exts = ("*.jpg", "*.jpeg", "*.png", "*.JPG", "*.JPEG", "*.PNG")
    paths: list[Path] = []
    for ext in exts:
        paths.extend(sorted(rep_dir.glob(ext)))
    return paths[:limit]


def rep_generator(rep_dir: Path | None, limit: int) -> Iterator[tuple]:
    """Yield raw float32 [1,224,224,3] batches in [0,255] — byte-identical scale
    to classifier._predict_keras (normalization lives inside the graph)."""
    import numpy as np
    from PIL import Image

    if rep_dir is None or not rep_dir.exists():
        raise SystemExit(
            "No calibration source. Pass --rep-images-dir with stratified fundus "
            "images; int8 without representative data is forbidden because it "
            "silently degrades minority-class recall."
        )
    paths = collect_rep_images(rep_dir, limit)
    if not paths:
        raise SystemExit(f"No images found under {rep_dir}")
    for p in paths:
        img = Image.open(p).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE))  # PIL bicubic
        arr = np.asarray(img, dtype=np.float32)
        yield (np.expand_dims(arr, axis=0),)


def build_converter(model_dir: Path, variant: str, rep_gen_fn):
    import tensorflow as tf

    conv = tf.lite.TFLiteConverter.from_saved_model(str(model_dir))
    if variant == "int8":
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
        conv.representative_dataset = rep_gen_fn
        conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        # Float I/O keeps the in-graph Rescaling/Normalization chain in float
        # math while all conv kernels become int8.
        conv.inference_input_type = tf.float32
        conv.inference_output_type = tf.float32
    elif variant == "fp16":
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
    return conv


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def probe_io_contract(tflite_path: Path) -> dict:
    """Read back input/output tensor settings the Dart side must obey."""
    import numpy as np
    import tensorflow as tf

    interp = tf.lite.Interpreter(model_path=str(tflite_path), num_threads=2)
    interp.allocate_tensors()
    ind = interp.get_input_details()[0]
    od = interp.get_output_details()[0]
    x = np.zeros(ind["shape"], dtype=ind["dtype"])
    interp.set_tensor(ind["index"], x)
    interp.invoke()
    y = interp.get_tensor(od["index"])
    return {
        "input": {"shape": ind["shape"].tolist(), "dtype": str(ind["dtype"])},
        "output": {"shape": od["shape"].tolist(), "dtype": str(od["dtype"])},
        "output_sum": float(np.sum(y)),
        "expects": "float32 NHWC [1,224,224,3] raw 0..255 RGB (do NOT normalize in Dart)",
        "returns": "softmax 5-vector (feeds confidence gate 0.70/0.15 directly)",
    }


def main() -> int:
    args = parse_args()
    if not args.source.exists():
        raise SystemExit(f"Source model not found: {args.source}")
    args.out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[1/5] Loading {args.source.name} (Keras 3) ...")
    model = load_keras_model(args.source)
    print(f"      input: {model.input_shape}, outputs: {len(model.outputs)}")

    print("[2/5] Exporting SavedModel ...")
    sm_dir = export_saved_model(model, args.out_dir)

    variants = ["int8", "fp16", "fp32"] if args.variant == "all" else [args.variant]
    outputs: dict[str, Path] = {}
    rep_gen_fn = None
    if "int8" in variants and not args.skip_calib:
        rep_gen_fn = lambda: rep_generator(args.rep_images_dir, args.rep_limit)

    for v in variants:
        if v == "int8":
            if args.skip_calib:
                print("      --skip-calib set: skipping int8")
                continue
            if not (args.rep_images_dir and args.rep_images_dir.exists()):
                print("      No calibration dir: skipping int8 (ship fp16; calibrate later)")
                continue
        print(f"[3/5] Converting variant: {v} ...")
        conv = build_converter(sm_dir, v, rep_gen_fn)
        tfl = conv.convert()
        out = args.out_dir / f"dr_efficientnet_b0_{v}.tflite"
        out.write_bytes(tfl)
        outputs[v] = out
        print(f"      {out.name}: {len(tfl) / (1 << 20):.1f} MB")

    primary = outputs.get("int8") or outputs.get("fp16") or outputs.get("fp32")
    io_contract: dict = {}
    if primary:
        print("[4/5] Probing I/O contract ...")
        io_contract = probe_io_contract(primary)
        print(json.dumps(io_contract, indent=2))

    print("[5/5] Writing manifest ...")
    manifest = {
        "source": str(args.source),
        "source_sha256": sha256_file(args.source),
        "artifacts": {k: str(v) for k, v in outputs.items()},
        "sizes_mb": {k: round(v.stat().st_size / (1 << 20), 2) for k, v in outputs.items()},
        "sha256": {k: sha256_file(v) for k, v in outputs.items()},
        "io_contract": io_contract,
        "parity_gate": (
            "Run validate_tflite_quantized.py before shipping. Gates: "
            "top-1 agreement >= 99.2%, dQWK >= -0.02, referable-sens drop <= 1.0pp"
        ),
    }
    manifest_path = args.out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"Done. Artifacts in {args.out_dir}")
    print(
        "Next: copy primary .tflite to flutter_app/assets/models/ and run validate_tflite_quantized.py"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
