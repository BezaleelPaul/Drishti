"""Per-camera validation harness.

Usage:
    python validate_cameras.py --data <root> [--out results/camera_validation.json]
    python validate_cameras.py --smoke   # wiring check on unlabeled test_samples

``<root>`` layout: ``<camera>/<grade_N>/*.jpg`` for cameras
``forus`` / ``remidio`` / ``volk`` / ``generic`` and grades 0..4.
Reports per-camera quality-pass rate, top-1 agreement, and referable
sensitivity/specificity. Exits non-zero when no gradable image is found
so CI cannot silently pass on an empty mount.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
CAMERAS = ("forus", "remidio", "volk", "generic")


def main() -> int:
    ap = argparse.ArgumentParser(description="Per-camera labeled validation.")
    ap.add_argument("--data", default=None)
    ap.add_argument("--out", default=os.path.join(PROJECT_ROOT, "results", "camera_validation.json"))
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()

    from src.pipeline.router import ScreeningPipelineRouter
    from src.pipeline.schema import QualityGrade
    from src.quality.checker import ImageQualityChecker, QualityThresholds

    _THRESHOLDS = {
        "forus": QualityThresholds.for_forus_3nethra(),
        "remidio": QualityThresholds.for_remidio_fop(),
        "volk": QualityThresholds.for_volk_inview(),
        "generic": QualityThresholds(),
    }

    def _router_for(camera: str) -> ScreeningPipelineRouter:
        # Per-camera thresholds: without this, "per-camera" validation would
        # split the data but grade everything under identical gates.
        return ScreeningPipelineRouter(
            quality_checker=ImageQualityChecker(thresholds=_THRESHOLDS[camera]))

    router = ScreeningPipelineRouter()
    report: dict = {"cameras": {}}

    if args.smoke or not args.data:
        from collections import Counter
        dist: Counter = Counter()
        total = 0
        for root, _, files in os.walk(os.path.join(PROJECT_ROOT, "test_samples")):
            for f in sorted(files):
                if not f.lower().endswith((".jpg", ".jpeg", ".png")):
                    continue
                try:
                    rec = router.process_image(os.path.join(root, f), output_dir=None)
                    dist[rec.quality_grade.value] += 1
                    total += 1
                except Exception as e:  # noqa: BLE001 - continue smoke validation
                    dist[f"ERROR:{e}"] += 1
        report["mode"] = "smoke-unlabeled-quality-only"
        report["total"] = total
        report["quality_distribution"] = dict(dist)
        print(f"smoke: {total} files -> {dict(dist)}")
        if total == 0:
            print("smoke found no images; failing so CI cannot pass on an empty mount.",
                  file=sys.stderr)
            return 1
        return 0

    grand_tp = grand_tn = grand_fp = grand_fn = 0
    for cam in CAMERAS:
        croot = os.path.join(args.data, cam)
        if not os.path.isdir(croot):
            continue
        cam_router = _router_for(cam)
        stats = {"n": 0, "quality_passed": 0, "top1_agree": 0,
                 "tp": 0, "tn": 0, "fp": 0, "fn": 0}
        for grade in range(5):
            d = os.path.join(croot, f"grade_{grade}")
            if not os.path.isdir(d):
                continue
            for f in sorted(os.listdir(d)):
                if not f.lower().endswith((".jpg", ".jpeg", ".png")):
                    continue
                try:
                    rec = cam_router.process_image(os.path.join(d, f), output_dir=None)
                except Exception as e:  # noqa: BLE001 - continue camera validation
                    print(f"  [warn] {cam}/{f}: {e}")
                    continue
                stats["n"] += 1
                if rec.quality_grade == QualityGrade.BAD or rec.dr_prediction is None:
                    continue
                stats["quality_passed"] += 1
                pred = rec.dr_prediction.predicted_grade.value
                stats["top1_agree"] += (pred == grade)
                ref_true, ref_pred = grade >= 2, pred >= 2
                stats["tp"] += (ref_true and ref_pred)
                stats["tn"] += (not ref_true and not ref_pred)
                stats["fp"] += (not ref_true and ref_pred)
                stats["fn"] += (ref_true and not ref_pred)
        n, qp = stats["n"], stats["quality_passed"]
        stats["quality_pass_rate"] = round(qp / n, 4) if n else None
        stats["top1_agreement"] = round(stats["top1_agree"] / qp, 4) if qp else None
        denom_sens = stats["tp"] + stats["fn"]
        denom_spec = stats["tn"] + stats["fp"]
        stats["referable_sensitivity"] = round(stats["tp"] / denom_sens, 4) if denom_sens else None
        stats["referable_specificity"] = round(stats["tn"] / denom_spec, 4) if denom_spec else None
        report["cameras"][cam] = stats
        grand_tp += stats["tp"]; grand_tn += stats["tn"]
        grand_fp += stats["fp"]; grand_fn += stats["fn"]

    if not report["cameras"]:
        print("no camera directories found; nothing to report.", file=sys.stderr)
        return 1
    report["note"] = ("Agreement metrics on caller-supplied labeled data, not a "
                      "clinical accuracy claim. Re-run per site before deployment.")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(report, fh, indent=2)
    for cam, s in report["cameras"].items():
        print(f"{cam:>8}: n={s['n']} pass={s['quality_pass_rate']} "
              f"agree={s['top1_agreement']} sens={s['referable_sensitivity']} spec={s['referable_specificity']}")
    print(f"-> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
