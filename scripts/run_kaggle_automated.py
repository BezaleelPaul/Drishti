#!/usr/bin/env python3
"""Automated Kaggle Execution & Model Ingestion Runner for Drishti-AI.

Flow:
  1. Validates Kaggle API credentials (~/.kaggle/kaggle.json).
  2. Generates kernel-metadata.json for the autonomous training notebook.
  3. Pushes the notebook to Kaggle's cloud GPU (T4/P100) via `kaggle kernels push`.
  4. Polls the remote kernel execution status until completion.
  5. Automatically downloads the trained models and scorecard.
  6. Deploys the INT8 TFLite model directly into flutter_app/assets/models/.
"""

import os
import sys
import json
import time
import shutil
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
KAGGLE_DIR = PROJECT_ROOT / "kaggle"
OUT_DIR = PROJECT_ROOT / "results" / "kaggle_retrain"
FLUTTER_MODELS_DIR = PROJECT_ROOT / "flutter_app" / "assets" / "models"


def check_prerequisites():
    """Ensure kaggle CLI is installed and credentials exist."""
    kaggle_bin = shutil.which("kaggle") or str(Path.home() / ".local" / "bin" / "kaggle")
    if not os.path.exists(kaggle_bin):
        print("\n[INFO] Installing official Kaggle CLI via pip...")
        subprocess.run([sys.executable, "-m", "pip", "install", "--user", "--break-system-packages", "kaggle"], check=True)
        kaggle_bin = str(Path.home() / ".local" / "bin" / "kaggle")

    res = subprocess.run([kaggle_bin, "config", "view"], capture_output=True, text=True)
    username = None
    for line in res.stdout.splitlines():
        if "username:" in line:
            username = line.split("username:")[-1].strip()
            break

    if not username:
        kaggle_json = Path.home() / ".kaggle" / "kaggle.json"
        if kaggle_json.exists():
            with open(kaggle_json) as f:
                username = json.load(f).get("username")

    if not username:
        print("\n[ERROR] Kaggle credentials not found at ~/.kaggle/access_token or ~/.kaggle/kaggle.json")
        sys.exit(1)

    print(f"[AUTH OK] Authenticated with Kaggle as: {username}")
    return kaggle_bin, username


def setup_metadata(username: str):
    """Generates the kernel-metadata.json file required by the Kaggle CLI."""
    kernel_slug = "drishti-high-recall-retrain"
    kernel_id = f"{username}/{kernel_slug}"
    
    metadata = {
        "id": kernel_id,
        "title": "Drishti High Recall Retrain",
        "code_file": "AUTONOMOUS_HIGH_RECALL_RETRAIN.ipynb",
        "language": "python",
        "kernel_type": "notebook",
        "is_private": "true",
        "enable_gpu": "true",
        "enable_internet": "true",
        "competition_sources": [
            "aptos2019-blindness-detection"
        ]
    }
    
    meta_path = KAGGLE_DIR / "kernel-metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2))
    print(f"[OK] Generated {meta_path} for kernel: {kernel_id}")
    return kernel_id


def push_and_monitor(kaggle_bin: str, kernel_id: str):
    """Pushes kernel to Kaggle (if not already running) and monitors its progress until complete."""
    # Check if already running
    status_cmd = [kaggle_bin, "kernels", "status", kernel_id]
    res = subprocess.run(status_cmd, capture_output=True, text=True)
    status_line = res.stdout.strip()
    
    if "running" in status_line.lower() or "queued" in status_line.lower():
        print(f"[INFO] Kernel {kernel_id} is already active: {status_line}")
    else:
        print(f"\n[1/4] Pushing notebook to Kaggle GPU cluster...")
        push_cmd = [kaggle_bin, "kernels", "push", "-p", str(KAGGLE_DIR)]
        res = subprocess.run(push_cmd, capture_output=True, text=True)
        print(res.stdout)
        if res.returncode != 0:
            print(f"[ERROR] Failed to push notebook: {res.stderr}")
            sys.exit(1)

    print(f"\n[2/4] Remote GPU execution active for {kernel_id}")
    print("      Monitoring training progress (this typically takes ~18-25 minutes on GPU)...")

    start_time = time.time()
    last_status = None
    last_print_time = 0

    while True:
        status_cmd = [kaggle_bin, "kernels", "status", kernel_id]
        res = subprocess.run(status_cmd, capture_output=True, text=True)
        status_line = res.stdout.strip()
        now = time.time()

        if status_line != last_status or (now - last_print_time) >= 60:
            elapsed = int(now - start_time)
            print(f"      [{elapsed // 60:02d}:{elapsed % 60:02d}] Status: {status_line}", flush=True)
            last_status = status_line
            last_print_time = now

        if "complete" in status_line.lower():
            print("\n[3/4] Remote training and validation completed successfully!", flush=True)
            break
        elif "error" in status_line.lower() or "failed" in status_line.lower():
            print(f"\n[ERROR] Remote execution failed: {status_line}", flush=True)
            print("Check logs at: https://www.kaggle.com/code/" + kernel_id, flush=True)
            sys.exit(1)

        time.sleep(30)


def download_and_deploy(kaggle_bin: str, kernel_id: str):
    """Downloads output artifacts and updates local Flutter app models."""
    print(f"\n[4/4] Downloading generated models and scorecards...")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    dl_cmd = [kaggle_bin, "kernels", "output", kernel_id, "-p", str(OUT_DIR)]
    res = subprocess.run(dl_cmd, capture_output=True, text=True)
    print(res.stdout)

    # Check for outputs
    tflite_int8 = OUT_DIR / "dr_efficientnet_b0_tuned_int8.tflite"
    scorecard_path = OUT_DIR / "clinical_scorecard.json"

    if scorecard_path.exists():
        scorecard = json.loads(scorecard_path.read_text())
        print("\n" + "="*60)
        print("          HOSPITAL READINESS SCORECARD")
        print("="*60)
        metrics = scorecard.get("metrics", {})
        print(f" Referable Sensitivity (Recall) : {metrics.get('referable_sensitivity_recall', 0)*100:.2f}%")
        print(f" Referable Specificity          : {metrics.get('referable_specificity', 0)*100:.2f}%")
        print(f" Quadratic Weighted Kappa (QWK) : {metrics.get('quadratic_weighted_kappa', 0):.4f}")
        print(f" Optimal Referral Threshold     : {scorecard.get('referable_threshold_t_star')}")
        print("="*60)

    if tflite_int8.exists() and FLUTTER_MODELS_DIR.exists():
        dest = FLUTTER_MODELS_DIR / "dr_efficientnet_b0_tuned_int8.tflite"
        shutil.copy2(tflite_int8, dest)
        print(f"[DEPLOYED] Copied winning INT8 model to {dest}")


def main():
    print("="*60)
    print("  DRISHTI-AI: AUTOMATED KAGGLE GPU RETRAINING RUNNER")
    print("="*60)
    kaggle_bin, username = check_prerequisites()
    kernel_id = setup_metadata(username)
    push_and_monitor(kaggle_bin, kernel_id)
    download_and_deploy(kaggle_bin, kernel_id)
    print("\n[ALL DONE] Pipeline retrained, tuned, and deployed!")


if __name__ == "__main__":
    main()
