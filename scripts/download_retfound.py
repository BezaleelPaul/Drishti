#!/usr/bin/env python3
"""Downloads Moorfields RETFound 5-Class Diabetic Retinopathy weights from Hugging Face Hub."""
import argparse
import os
import sys
import shutil

from huggingface_hub import hf_hub_download

REPO_ID = "bswift/RETfound_eyepacs_DR"
WEIGHT_FILE = "pytorch_model.bin"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET_DIR = os.path.join(PROJECT_ROOT, "models")
TARGET_PATH = os.path.join(TARGET_DIR, "retfound_eyepacs_5class.pth")


def download_weights(target_path: str = TARGET_PATH) -> str:
    print(f"=== Downloading RETFound 5-Class Weights from Hugging Face ({REPO_ID}) ===")
    os.makedirs(os.path.dirname(os.path.abspath(target_path)), exist_ok=True)
    
    print(f"Destination: {target_path}")
    print("Initiating download (1.21 GB, Moorfields ViT-Large backbone fine-tuned on EyePACS)...")
    
    dl_path = hf_hub_download(
        repo_id=REPO_ID,
        filename=WEIGHT_FILE,
    )
    shutil.copy(dl_path, target_path)
    file_size_mb = os.path.getsize(target_path) / (1024 * 1024)
    print(f"Download complete! Saved to {target_path} ({file_size_mb:.1f} MB)")
    return target_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download RETFound weights")
    parser.add_argument("--output", default=TARGET_PATH, help="Target file path")
    args = parser.parse_args()
    download_weights(args.output)
