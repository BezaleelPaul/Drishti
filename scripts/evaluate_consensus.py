#!/usr/bin/env python3
"""
CLI Evaluation tool for Dual-Engine Consensus Classifier (DRDetect CNN + Meta DINOv3-Large ViT).
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

from src.classification.consensus_classifier import DualEngineConsensusClassifier


def main():
    parser = argparse.ArgumentParser(
        description="Run inference using Dual-Engine Consensus Classifier (DRDetect + DINOv3)."
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
        help="Directory of retinal images to evaluate.",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cpu",
        help="Inference device (cpu or cuda).",
    )
    parser.add_argument(
        "--no-tta",
        action="store_true",
        help="Disable 4-view TTA for DINOv3 (faster, but vulnerable to rotation).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON output.",
    )

    args = parser.parse_args()

    print("=" * 88)
    print(" Drishti-AI: Dual-Engine Consensus Evaluation (DRDetect CNN + Meta DINOv3 ViT)")
    print("=" * 88)

    try:
        classifier = DualEngineConsensusClassifier(
            device=args.device,
            use_tta=not args.no_tta,
        )
        print(f"[OK] DRDetect Model: {classifier.onnx_path}")
        print(f"[OK] DINOv3 Checkpoint: {classifier.dinov3_path}")
        print(f"[OK] TTA 4-View Rotation Smoothing: {'ENABLED' if not args.no_tta else 'DISABLED'}\n")
    except Exception as e:
        print(f"[ERROR] Failed to initialize consensus classifier: {e}")
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

    header = f"{'Image':<32} | {'DRDetect Score':<15} | {'DINOv3 Class':<14} | {'Consensus':<14} | {'Clinical Action'}"
    print(header)
    print("-" * len(header))

    results = []
    for img_path in image_paths:
        t0 = time.perf_counter()
        report = classifier.evaluate_consensus(img_path)
        t1 = time.perf_counter()
        lat_ms = (t1 - t0) * 1000.0

        rel_name = os.path.basename(img_path)
        stat_color = "CONSENSUS" if report.consensus_achieved else "DISAGREEMENT"

        if report.consensus_achieved:
            if report.triage_tier == 0:
                act = "Routine 12-Month Rescreen"
            elif report.triage_tier == 1:
                act = "Primary Care Followup"
            else:
                act = "Fast-Track Hospital Referral"
        else:
            act = "Mandatory Human Tele-Review"

        print(
            f"{rel_name:<32} | sc:{report.drdetect_score:<5.2f} (G{report.drdetect_grade}) | "
            f"Class {report.dinov3_class:<3} ({max(report.dinov3_probabilities)*100:4.1f}%) | "
            f"{stat_color:<14} | {act}"
        )

        results.append(
            {
                "image": rel_name,
                "consensus_achieved": report.consensus_achieved,
                "status": report.status,
                "drdetect_score": report.drdetect_score,
                "drdetect_grade": report.drdetect_grade,
                "dinov3_class": report.dinov3_class,
                "dinov3_probabilities": report.dinov3_probabilities,
                "triage_tier": report.triage_tier,
                "triage_label": report.triage_label,
                "action": act,
                "latency_ms": round(lat_ms, 2),
            }
        )

    print("-" * len(header))
    print(f"Evaluated {len(image_paths)} images successfully.\n")

    if args.json:
        print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
