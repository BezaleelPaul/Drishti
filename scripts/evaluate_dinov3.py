#!/usr/bin/env python3
"""
CLI Evaluation tool for fine-tuned Meta DINOv3-Large 3-Class ICDR Model.
Evaluates fundus images using: models/TL_dinov3_large_fine_tune_3class_final_icdr_best.pth
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from src.classification.dinov3_classifier import DINOv3ICDRClassifier


def main():
    parser = argparse.ArgumentParser(
        description="Run inference using Meta DINOv3-Large 3-Class ICDR DR Model."
    )
    parser.add_argument(
        "--image",
        type=str,
        help="Path to a single retinal fundus image.",
    )
    parser.add_argument(
        "--dir",
        type=str,
        default=os.path.join(_REPO_ROOT, "test_samples", "01_real_clinical_fundus"),
        help="Directory of retinal images to evaluate (default: test_samples/01_real_clinical_fundus).",
    )
    parser.add_argument(
        "--weights",
        type=str,
        default=None,
        help="Path to .pth checkpoint (default: models/TL_dinov3_large_fine_tune_3class_final_icdr_best.pth).",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cpu",
        help="Inference device (cpu or cuda).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON output.",
    )

    args = parser.parse_args()

    print("=" * 72)
    print(" Drishti-AI: Meta DINOv3-Large 3-Class ICDR Evaluation")
    print("=" * 72)

    try:
        classifier = DINOv3ICDRClassifier(checkpoint_path=args.weights, device=args.device)
        print(f"[OK] Loaded checkpoint: {classifier.checkpoint_path}")
        print(f"[OK] Running on device: {classifier.device}\n")
    except Exception as e:
        print(f"[ERROR] Failed to load model: {e}")
        sys.exit(1)

    image_paths: list[str] = []
    if args.image:
        if not os.path.exists(args.image):
            print(f"[ERROR] Image not found: {args.image}")
            sys.exit(1)
        image_paths.append(args.image)
    elif args.dir:
        if not os.path.isdir(args.dir):
            print(f"[ERROR] Directory not found: {args.dir}")
            sys.exit(1)
        for root, _, files in os.walk(args.dir):
            for f in sorted(files):
                if f.lower().endswith((".jpg", ".jpeg", ".png", ".tif", ".bmp")):
                    image_paths.append(os.path.join(root, f))

    if not image_paths:
        print("[WARN] No images found to evaluate.")
        sys.exit(0)

    results = []
    header = f"{'Image':<35} | {'ICDR Grade':<12} | {'Label':<28} | {'Conf':<7} | {'Referable'}"
    print(header)
    print("-" * len(header))

    total_latency = 0.0
    for img_path in image_paths:
        t0 = time.perf_counter()
        res = classifier.predict(img_path)
        t1 = time.perf_counter()
        lat_ms = (t1 - t0) * 1000.0
        total_latency += lat_ms

        rel_name = os.path.basename(img_path)
        ref_str = "YES" if res.is_referable else "NO"
        print(
            f"{rel_name:<35} | Grade {res.predicted_class:<6} | {res.class_label:<28} | {res.confidence * 100:5.1f}% | {ref_str}"
        )

        results.append(
            {
                "image": rel_name,
                "predicted_class": res.predicted_class,
                "class_label": res.class_label,
                "probabilities": res.probabilities,
                "confidence": res.confidence,
                "is_referable": res.is_referable,
                "latency_ms": round(lat_ms, 2),
            }
        )

    avg_lat = total_latency / len(image_paths) if image_paths else 0.0
    print("-" * len(header))
    print(f"Evaluated {len(image_paths)} images. Mean latency: {avg_lat:.1f} ms/image\n")

    if args.json:
        print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
