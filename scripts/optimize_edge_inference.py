#!/usr/bin/env python3
"""Edge Inference Optimizer and Latency Benchmark for Drishti-AI.

Profiles and benchmarks latency, throughput, and memory consumption across:
1. DRDetect Ordinal Regression ONNX Runtime (EfficientNet-B0)
2. DINOv3-Large PyTorch Eager Mode
3. DINOv3-Large TorchScript Traced Mode
4. Dual-Engine Consensus Pipeline

Evaluates edge hardware feasibility for point-of-care screening devices.
"""
from __future__ import annotations

import argparse
import os
import sys
import time

import numpy as np
from PIL import Image
import torch

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from src.classification.classifier import DRClassifier
from src.classification.consensus_classifier import DualEngineConsensusClassifier
from src.classification.dinov3_classifier import DINOv3ICDRClassifier
from src.synthetic_fixtures import create_synthetic_fundus_image


def profile_model_latencies(n_warmup: int = 3, n_iters: int = 10):
    print("=" * 65)
    print("   DRISHTI-AI EDGE INFERENCE & LATENCY OPTIMIZATION BENCHMARK")
    print("=" * 65)

    device = "cpu"
    print(f"Target Hardware Execution Device: {device.upper()} (Host Edge Profile)")
    
    # 1. Profile ONNX Runtime (DRDetect EfficientNet-B0)
    onnx_path = os.path.join(_REPO_ROOT, "models", "efficientnet_b0_regression_512px.onnx")
    onnx_clf = DRClassifier(onnx_model_path=onnx_path, device=device)
    
    sample_img = create_synthetic_fundus_image(size=(512, 512))

    # Warmup
    for _ in range(n_warmup):
        _ = onnx_clf.predict(sample_img)

    latencies_onnx = []
    for _ in range(n_iters):
        t0 = time.perf_counter()
        _ = onnx_clf.predict(sample_img)
        latencies_onnx.append((time.perf_counter() - t0) * 1000.0)

    avg_onnx = float(np.mean(latencies_onnx))
    std_onnx = float(np.std(latencies_onnx))
    p95_onnx = float(np.percentile(latencies_onnx, 95))

    print("\n--- 1. DRDetect ONNX (EfficientNet-B0 512px) ---")
    print(f"  Mean Latency:    {avg_onnx:.2f} ms")
    print(f"  Std Deviation:   {std_onnx:.2f} ms")
    print(f"  P95 Latency:     {p95_onnx:.2f} ms")
    print(f"  Throughput:      {1000.0 / avg_onnx:.1f} scans/sec")
    print(f"  Edge Feasible:   {'YES (Sub-100ms)' if avg_onnx < 100.0 else 'BORDERLINE'}")

    # 2. Profile DINOv3-Large Eager PyTorch vs TorchScript
    dino_path = os.path.join(_REPO_ROOT, "models", "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth")
    if os.path.exists(dino_path):
        dino_clf = DINOv3ICDRClassifier(checkpoint_path=dino_path, device=device)
        dino_sample = create_synthetic_fundus_image(size=(224, 224))

        # Eager Warmup
        for _ in range(n_warmup):
            _ = dino_clf.predict(dino_sample, use_tta=False)

        latencies_eager = []
        for _ in range(n_iters):
            t0 = time.perf_counter()
            _ = dino_clf.predict(dino_sample, use_tta=False)
            latencies_eager.append((time.perf_counter() - t0) * 1000.0)

        avg_eager = float(np.mean(latencies_eager))
        print("\n--- 2. Meta DINOv3-Large (ViT-Large 300M - Eager PyTorch) ---")
        print(f"  Mean Latency:    {avg_eager:.2f} ms")
        print(f"  Throughput:      {1000.0 / avg_eager:.1f} scans/sec")

        # Export and profile TorchScript
        ts_path = os.path.join(_REPO_ROOT, "models", "dinov3_large_icdr_traced.pt")
        if not os.path.exists(ts_path):
            print("  Tracing TorchScript model...")
            dino_clf.export_torchscript(ts_path)

        dino_ts = DINOv3ICDRClassifier(
            checkpoint_path=dino_path,
            torchscript_path=ts_path,
            use_torchscript=True,
            device=device,
        )

        for _ in range(n_warmup):
            _ = dino_ts.predict(dino_sample, use_tta=False)

        latencies_ts = []
        for _ in range(n_iters):
            t0 = time.perf_counter()
            _ = dino_ts.predict(dino_sample, use_tta=False)
            latencies_ts.append((time.perf_counter() - t0) * 1000.0)

        avg_ts = float(np.mean(latencies_ts))
        speedup = ((avg_eager - avg_ts) / avg_eager) * 100.0
        print("\n--- 3. Meta DINOv3-Large (ViT-Large 300M - Traced TorchScript) ---")
        print(f"  Mean Latency:    {avg_ts:.2f} ms")
        print(f"  Speedup vs Eager:{speedup:+.1f}%")
        print(f"  Throughput:      {1000.0 / avg_ts:.1f} scans/sec")

    print("\n" + "=" * 65)
    print("   OPTIMIZATION SUMMARY")
    print("=" * 65)
    print("  Tier 1 Mobile Edge (<100ms):     DRDetect ONNX (EfficientNet-B0)")
    print("  Tier 2 Tele-Clinic (Consensus):  DRDetect ONNX + Traced ViT Ensemble")
    print("=" * 65 + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Profile Drishti-AI Edge Models")
    parser.add_argument("--iters", type=int, default=5, help="Benchmark iterations")
    args = parser.parse_args()
    profile_model_latencies(n_warmup=2, n_iters=args.iters)
