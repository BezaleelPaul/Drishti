"""Calibration evaluation: Expected Calibration Error (ECE) + reliability data.

Usage:
    python evaluate_calibration.py --data <root> [--bins 10] [--out results/calibration.json]
    python evaluate_calibration.py --check        # deterministic self-test, no models

``<root>`` is an ImageFolder-style directory with ``grade_0`` .. ``grade_4``
subdirectories of labeled fundus images. Top-1 accuracy is binned by
predicted confidence; ECE = sum_b |acc_b - conf_b| * (n_b / N).

There is deliberately NO synthetic mode: calibration against invented
labels would fabricate a reliability claim. ``--check`` only proves the
binning machinery works on a fixed toy example.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
N_BINS = 10


def compute_ece(items, n_bins: int = N_BINS) -> dict:
    """items: list of (confidence, correct_bool). Returns ECE/MCE + bins."""
    bins = [{"count": 0, "acc_sum": 0.0, "conf_sum": 0.0} for _ in range(n_bins)]
    for conf, correct in items:
        c = float(conf)
        if not math.isfinite(c):
            raise ValueError(f"Non-finite confidence {conf!r}; refusing to bin.")
        c = min(1.0, max(0.0, c))
        idx = min(n_bins - 1, int(c * n_bins))
        b = bins[idx]
        b["count"] += 1
        b["acc_sum"] += 1.0 if correct else 0.0
        b["conf_sum"] += c
    total = len(items)
    ece = 0.0
    mce = 0.0
    out_bins = []
    for i, b in enumerate(bins):
        if b["count"] == 0:
            out_bins.append({"bin": [i / n_bins, (i + 1) / n_bins], "count": 0,
                             "accuracy": None, "mean_confidence": None, "gap": None})
            continue
        acc = b["acc_sum"] / b["count"]
        mconf = b["conf_sum"] / b["count"]
        gap = abs(acc - mconf)
        ece += (b["count"] / total) * gap
        mce = max(mce, gap)
        out_bins.append({"bin": [round(i / n_bins, 2), round((i + 1) / n_bins, 2)],
                         "count": b["count"], "accuracy": round(acc, 4),
                         "mean_confidence": round(mconf, 4), "gap": round(gap, 4)})
    return {"n": total, "ece": round(ece, 4), "mce": round(mce, 4), "bins": out_bins}


def run_self_check() -> dict:
    # Perfectly calibrated toy: 10 items at 0.9 conf, 9 correct -> gap 0.0 in
    # bin 9; plus 10 items at 0.5 conf, 5 correct. ECE = 0.5*0 + 0.5*0 = 0.0.
    items = [(0.9, True)] * 9 + [(0.9, False)] + [(0.5, True)] * 5 + [(0.5, False)] * 5
    res = compute_ece(items, n_bins=10)
    assert res["n"] == 20, res
    assert res["ece"] == 0.0, res
    assert res["bins"][9]["count"] == 10 and res["bins"][9]["accuracy"] == 0.9, res["bins"][9]
    assert res["bins"][5]["count"] == 10 and res["bins"][5]["accuracy"] == 0.5, res["bins"][5]
    # Miscalibrated toy: always 1.0 confident, right half the time -> ECE 0.5.
    bad = compute_ece([(1.0, i % 2 == 0) for i in range(10)], n_bins=10)
    assert bad["ece"] == 0.5, bad
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description="DR classifier calibration (ECE + reliability bins).")
    ap.add_argument("--data", default=None, help="Root with grade_0..grade_4 subdirs.")
    ap.add_argument("--bins", type=int, default=N_BINS)
    ap.add_argument("--out", default=os.path.join(PROJECT_ROOT, "results", "calibration.json"))
    ap.add_argument("--check", action="store_true", help="Deterministic self-test only.")
    args = ap.parse_args()
    if args.bins is not None and args.bins < 1:
        ap.error("--bins must be >= 1.")

    if args.check or not args.data:
        res = run_self_check()
        print(f"self-check OK: n={res['n']} ece={res['ece']} mce={res['mce']}")
        return 0

    from PIL import Image

    from src.classification.classifier import DRClassifier

    items = []
    clf = DRClassifier()
    print(f"model_backend={clf.get_backend()}")
    for grade in range(5):
        d = os.path.join(args.data, f"grade_{grade}")
        if not os.path.isdir(d):
            print(f"skip missing {d}")
            continue
        files = sorted(f for f in os.listdir(d) if f.lower().endswith((".jpg", ".jpeg", ".png")))
        for f in files:
            try:
                pred = clf.predict(Image.open(os.path.join(d, f)).convert("RGB"))
                items.append((pred.confidence, pred.predicted_grade.value == grade))
            except Exception as e:  # noqa: BLE001 - continue grading remaining samples
                print(f"  [warn] {f}: {e}")
    if not items:
        print("no images graded; nothing to report.", file=sys.stderr)
        return 1
    res = compute_ece(items, n_bins=args.bins)
    res["model_backend"] = clf.get_backend()
    res["note"] = ("Top-1 calibration on caller-supplied labeled data. "
                   "Not a clinical accuracy claim; re-run per camera/site.")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(res, fh, indent=2)
    print(f"n={res['n']} ECE={res['ece']} MCE={res['mce']} -> {args.out}")
    print(f"{'bin':>12} {'n':>5} {'acc':>6} {'conf':>6} {'gap':>6}")
    for b in res["bins"]:
        if b["count"]:
            lo, hi = b["bin"]
            print(f"[{lo:.1f},{hi:.1f}) {b['count']:>5} {b['accuracy']:>6} {b['mean_confidence']:>6} {b['gap']:>6}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
