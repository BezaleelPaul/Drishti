"""
CLI runner for the AI-Assisted Diabetic Retinopathy Screening Pipeline.
Processes single images or directories, applying the full 11-node decision flow.
"""

import argparse
import os
import sys

from src.pipeline.router import ScreeningPipelineRouter


def main():
    parser = argparse.ArgumentParser(
        description="SIH 2026: AI-Assisted Diabetic Retinopathy Screening Pipeline"
    )
    parser.add_argument(
        "--image",
        type=str,
        help="Path to a single retinal fundus image file.",
    )
    parser.add_argument(
        "--input_dir",
        type=str,
        help="Path to directory containing retinal fundus images.",
    )
    parser.add_argument(
        "--output_dir",
        type=str,
        default="results",
        help="Directory to save screening reports and Grad-CAM overlays.",
    )
    parser.add_argument(
        "--recaptures",
        type=int,
        default=0,
        help="Current count of previous recapture attempts for this session.",
    )

    args = parser.parse_args()

    if args.recaptures < 0:
        parser.error("--recaptures must be >= 0")
    if args.image and not os.path.isfile(args.image):
        parser.error(f"--image not found or not a file: {args.image}")
    if args.input_dir and not os.path.isdir(args.input_dir):
        parser.error(f"--input_dir not found or not a directory: {args.input_dir}")

    if not args.image and not args.input_dir:
        # Default to running sample images if neither is passed
        sample_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "test_samples", "curated"
        )
        if os.path.isdir(sample_dir):
            args.input_dir = sample_dir
        else:
            parser.print_help()
            sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)
    router = ScreeningPipelineRouter()

    image_paths = []
    if args.image:
        image_paths.append(args.image)
    elif args.input_dir:
        valid_exts = (".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp")
        for f in sorted(os.listdir(args.input_dir)):
            if f.lower().endswith(valid_exts):
                image_paths.append(os.path.join(args.input_dir, f))

    if not image_paths:
        print("No processable images found — nothing to do.", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'='*70}")
    print("SIH 2026: AI-Assisted DR Screening Pipeline Execution")
    print(f"Processing {len(image_paths)} image(s)...")
    print(f"{'='*70}\n")

    failures = 0
    for idx, path in enumerate(image_paths, 1):
        filename = os.path.basename(path)
        img_out_dir = os.path.join(args.output_dir, os.path.splitext(filename)[0])

        try:
            record = router.process_image(
                image_input=path,
                recapture_attempt_count=args.recaptures,
                output_dir=img_out_dir,
            )
        except Exception as exc:  # noqa: BLE001 - report and continue per input file
            failures += 1
            print(f"[{idx}/{len(image_paths)}] File: {filename} — FAILED: {exc}",
                  file=sys.stderr)
            continue

        print(f"[{idx}/{len(image_paths)}] File: {filename}")
        print("-" * 50)
        print(record.format_report_text())
        print("-" * 50)
        print(f"Result files saved to: {img_out_dir}\n")

    print(f"Done: {len(image_paths) - failures}/{len(image_paths)} succeeded, "
          f"{failures} failed.")
    if failures:
        sys.exit(2)


if __name__ == "__main__":
    main()
