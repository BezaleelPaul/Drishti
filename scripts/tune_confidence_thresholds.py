import csv
import itertools
import os
import sys

sys.path.insert(0, os.getcwd())

import numpy as np

from src.pipeline.confidence import ConfidenceConfig, ConfidenceEvaluator
from src.pipeline.schema import DRClassificationResult, DRGrade


def qwk(y_pred, y_true):
    h = np.zeros((5, 5))
    for t, p in zip(y_true, y_pred):
        h[t, p] += 1
    w = (np.arange(5)[:, None] - np.arange(5)[None, :]) ** 2 / 16
    e = np.outer(h.sum(1), h.sum(0)) / h.sum()
    return 1 - (w * h).sum() / (w * e).sum()


default_csvs = (
    "results/labeled_tta_off_200_predictions.csv",
    "results/labeled_tta_on_200_predictions.csv",
    "results/labeled_evaluation_drdetect_no_tta_predictions.csv",
    "results/labeled_evaluation_drdetect_tta_on_predictions.csv",
)
csv_paths = sys.argv[1:] or default_csvs

for csv_path in csv_paths:
    if not os.path.exists(csv_path):
        print(f"--- {csv_path}: not found, skipping ---")
        continue
    with open(csv_path, newline="") as fh:
        recs = list(csv.DictReader(fh))
    print(f"--- {csv_path}  n={len(recs)} ---")
    print("conf margin | released relAcc relQWK missedRef")
    for conf_t, marg_t in itertools.product(
        (0.50, 0.55, 0.60, 0.65, 0.70), (0.05, 0.10, 0.15, 0.20)
    ):
        ev = ConfidenceEvaluator(
            ConfidenceConfig(min_confidence_threshold=conf_t, min_ambiguity_margin=marg_t)
        )
        rel, yp, yt = [], [], []
        for r in recs:
            probs = [float(x) for x in r["probabilities"].split(";")]
            res = DRClassificationResult(
                predicted_grade=DRGrade(int(r["pred"])),
                probabilities=probs,
                confidence=max(
                    probs
                ),  # CSV confidence is 4-decimal rounded; recompute to satisfy Rule 0
                top2_margin=float(r["top2_margin"]),
                is_referable=int(r["pred"]) >= 2,
            )
            a = ev.evaluate(res)
            if a.is_confident and not a.is_ambiguous:
                rel.append(r)
                yp.append(int(r["pred"]))
                yt.append(int(r["label"]))
        if not rel:
            continue
        missed = sum(1 for r in rel if int(r["label"]) >= 2 and int(r["pred"]) < 2)
        acc = sum(1 for p, t in zip(yp, yt) if p == t) / len(rel)
        print(
            f"{conf_t:5.2f} {marg_t:6.2f} | {len(rel):>8} {acc:>7.3f} {qwk(yp, yt):>7.3f} {missed:>9}"
        )
