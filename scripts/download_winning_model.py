#!/usr/bin/env python3
"""
Downloads the benchmark-winning DR screening model:
DRDetect Ordinal Regression (adarshcod30/drdetect-dr-screening)
QWK: 0.8931 | Referable Sensitivity: 99.7% | Latency: ~334 ms
"""

import sys
from pathlib import Path
import urllib.request

WINNING_REPO = "adarshcod30/drdetect-dr-screening"
ONNX_FILENAME = "efficientnet_b0_regression_512px.onnx"
DOWNLOAD_URL = f"https://huggingface.co/{WINNING_REPO}/resolve/main/{ONNX_FILENAME}"

DEST_DIRS = [
    Path("models"),
    Path("flutter_app/assets/models"),
    Path("release/models"),
]

def download_winning_model():
    print("=" * 68)
    print(" DOWNLOADING BENCHMARK WINNING MODEL: DRDetect Ordinal Regression")
    print(f" Source: {WINNING_REPO}")
    print(f" Target: {ONNX_FILENAME}")
    print("=" * 68)

    for dest in DEST_DIRS:
        dest.mkdir(parents=True, exist_ok=True)
        target_path = dest / ONNX_FILENAME
        if target_path.exists() and target_path.stat().st_size > 1000:
            print(f"[OK] Already exists: {target_path} ({target_path.stat().st_size / 1024 / 1024:.2f} MB)")
            continue

        print(f"[DOWNLOADING] Fetching to {target_path}...")
        try:
            req = urllib.request.Request(DOWNLOAD_URL, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req) as resp, open(target_path, "wb") as f:
                total_bytes = 0
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    total_bytes += len(chunk)
                    print(f"  Downloaded: {total_bytes / 1024 / 1024:.1f} MB...", end="\r")
            print(f"\n[DONE] Saved successfully to {target_path} ({total_bytes / 1024 / 1024:.2f} MB)")
        except Exception as e:
            print(f"[ERROR] Failed downloading to {target_path}: {e}")

if __name__ == "__main__":
    download_winning_model()
