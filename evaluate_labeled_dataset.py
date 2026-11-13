"""Labeled-dataset evaluation for Drishti-AI.

Measures, on a real labeled fundus dataset (default: 2810-image EyePACS
validation split via HuggingFace):

  1. Domain-gate behaviour   -> coverage / false-reject rate (FRR)
  2. Model 2 accuracy        -> top-1, +/-1 agreement, QWK, per-class recall
  3. Referable-DR triage     -> sensitivity / specificity / PPV / NPV
  4. Uncertainty gate        -> accuracy of released vs abstained predictions
  5. Calibration             -> ECE (reuse of evaluate_calibration.compute_ece)

Usage:
    python evaluate_labeled_dataset.py                     # full set, model mode
    python evaluate_labeled_dataset.py --limit 400 --mode quality
    python evaluate_labeled_dataset.py --parquet <path.parquet>

Outputs:
    results/labeled_evaluation.json          summary metrics
    results/labeled_evaluation_predictions.csv   per-image audit trail
"""

from __future__ import annotations

import argparse
import csv
import importlib
import json
import os
import sys
import time

import numpy as np

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

DEFAULT_REPO = "youssefedweqd/Diabetic_Retinopathy_Detection"
DEFAULT_PARQUET = "data/validation-00000-of-00001.parquet"
REFERABLE_MIN = 2


def quadratic_kappa(y_true: list[int], y_pred: list[int], n_classes: int = 5) -> float:
    hist = np.zeros((n_classes, n_classes), dtype=np.float64)
    for t, p in zip(y_true, y_pred):
        hist[t, p] += 1.0
    total = hist.sum()
    if total == 0:
        return 0.0
    idx = np.arange(n_classes)
    weights = ((idx[:, None] - idx[None, :]) ** 2) / ((n_classes - 1) ** 2)
    expected = np.outer(hist.sum(1), hist.sum(0)) / total
    den = (weights * expected).sum()
    if den <= 0:
        return 1.0
    return float(1.0 - (weights * hist).sum() / den)


def binary_rates(y_true: list[int], y_pred: list[int], minimum: int = REFERABLE_MIN) -> dict:
    yt = [1 if t >= minimum else 0 for t in y_true]
    yp = [1 if p >= minimum else 0 for p in y_pred]
    tp = sum(1 for t, p in zip(yt, yp) if t == 1 and p == 1)
    tn = sum(1 for t, p in zip(yt, yp) if t == 0 and p == 0)
    fp = sum(1 for t, p in zip(yt, yp) if t == 0 and p == 1)
    fn = sum(1 for t, p in zip(yt, yp) if t == 1 and p == 0)
    safe = lambda a, b: round(a / b, 4) if b else None
    return {
        "tp": tp,
        "tn": tn,
        "fp": fp,
        "fn": fn,
        "sensitivity": safe(tp, tp + fn),
        "specificity": safe(tn, tn + fp),
        "ppv": safe(tp, tp + fp),
        "npv": safe(tn, tn + fn),
        "accuracy": safe(tp + tn, tp + tn + fp + fn),
        "n_positive": tp + fn,
        "n_negative": tn + fp,
    }


def classification_metrics(y_true: list[int], y_pred: list[int]) -> dict:
    n = len(y_true)
    if n == 0:
        return {"n": 0}
    per_class = {}
    for c in range(5):
        tp = sum(1 for t, p in zip(y_true, y_pred) if t == c and p == c)
        support = sum(1 for t in y_true if t == c)
        pred_c = sum(1 for p in y_pred if p == c)
        precision = tp / pred_c if pred_c else None
        recall = tp / support if support else None
        f1 = (
            round(2 * precision * recall / (precision + recall), 4)
            if precision and recall
            else (0.0 if precision is not None and recall is not None else None)
        )
        per_class[f"grade_{c}"] = {
            "support": support,
            "precision": round(precision, 4) if precision is not None else None,
            "recall": round(recall, 4) if recall is not None else None,
            "f1": f1,
        }
    recalls = [v["recall"] for v in per_class.values() if v["recall"] is not None]
    f1_pairs = [(v["f1"], v["support"]) for v in per_class.values() if v["f1"] is not None]
    f1s = [p[0] for p in f1_pairs]
    return {
        "n": n,
        "accuracy": round(sum(1 for t, p in zip(y_true, y_pred) if t == p) / n, 4),
        "within_one_accuracy": round(
            sum(1 for t, p in zip(y_true, y_pred) if abs(t - p) <= 1) / n, 4
        ),
        "balanced_accuracy": round(float(np.mean(recalls)), 4) if recalls else None,
        "macro_f1": round(float(np.mean(f1s)), 4) if f1s else None,
        "weighted_f1": (
            round(
                float(np.average([p[0] for p in f1_pairs], weights=[p[1] for p in f1_pairs])),
                4,
            )
            if f1_pairs and sum(p[1] for p in f1_pairs) > 0
            else None
        ),
        "quadratic_weighted_kappa": round(quadratic_kappa(y_true, y_pred), 4),
        "referable_dr": binary_rates(y_true, y_pred),
        "per_class": per_class,
        "confusion_matrix": [
            [sum(1 for t, p in zip(y_true, y_pred) if t == i and p == j) for j in range(5)]
            for i in range(5)
        ],
    }


def read_labels(parquet_path: str) -> list[int]:
    """Reads only the label column (a few KB) for stratification."""
    pf = importlib.import_module("pyarrow.parquet").ParquetFile(parquet_path)
    return [int(x) for x in pf.read(columns=["label"]).column("label").to_pylist()]


def stratified_indices(labels: list[int], limit: int) -> list[int]:
    """Chooses `limit` row indices with per-class head sampling (seed-fixed)."""
    if limit >= len(labels):
        return list(range(len(labels)))
    import random

    by_class: dict[int, list[int]] = {}
    for i, y in enumerate(labels):
        by_class.setdefault(y, []).append(i)
    for y, indices in by_class.items():
        random.Random(y).shuffle(indices)
    per = max(1, limit // len(by_class))
    chosen: list[int] = []
    for y in sorted(by_class):
        chosen.extend(by_class[y][:per])
    if len(chosen) < limit:
        leftover = [i for i in range(len(labels)) if i not in set(chosen)]
        chosen.extend(leftover[: limit - len(chosen)])
    return sorted(chosen[:limit])


def iter_fundus_rows(parquet_path: str, keep_indices: list[int] | None = None):
    """Streams (jpeg_bytes, label) rows without materializing the dataset.

    This machine has ~8 GB RAM; eager-loading all 2,810 multi-megapixel JPEG
    blobs (several GB) OOM-killed the run mid-flight. Reads happen in small
    batches and each row is yielded immediately so peak memory stays ~batch
    size, independent of dataset length.
    """
    pf = importlib.import_module("pyarrow.parquet").ParquetFile(parquet_path)
    keep = None if keep_indices is None else set(keep_indices)
    row_no = 0
    for batch in pf.iter_batches(batch_size=64, columns=["image", "label"]):
        imgs = batch.column("image")
        labs = batch.column("label").to_pylist()
        for j, lab in enumerate(labs):
            if keep is None or row_no in keep:
                record = imgs[int(j)].as_py()
                blob = record.get("bytes") if isinstance(record, dict) else record
                if blob is None:
                    raise ValueError(f"Parquet row {row_no} has no image bytes.")
                yield blob, int(lab)
            row_no += 1


def load_records_csv(path: str) -> list[dict]:
    records = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            records.append(
                {
                    "index": int(row["index"]),
                    "label": int(row["label"]),
                    "pred": int(row["pred"]),
                    "confidence": float(row["confidence"]),
                    "top2_margin": float(row["top2_margin"]),
                    "probabilities": row.get("probabilities", ""),
                    "gate": row["gate"],
                    "gate_reason": row["gate_reason"],
                    "confident": row["confident"] in ("True", "true", "1"),
                    "quality": row.get("quality", ""),
                }
            )
    return records


def build_report(records: list[dict], args, backend: str, wall_seconds: float) -> dict:
    from evaluate_calibration import compute_ece

    n = len(records)
    labels_l = [r["label"] for r in records]
    preds_l = [r["pred"] for r in records]

    kept_all = list(range(n))
    kept_gated = [i for i, r in enumerate(records) if r["gate"] != "NOT_FUNDUS"]
    kept_released = [i for i in kept_gated if records[i]["confident"]]

    def view(indices):
        yt = [labels_l[i] for i in indices]
        yp = [preds_l[i] for i in indices]
        out = classification_metrics(yt, yp)
        if out.get("n"):
            out["ece"] = compute_ece(
                [
                    (records[i]["confidence"], records[i]["pred"] == records[i]["label"])
                    for i in indices
                ]
            )["ece"]
        return out

    gate_counts = {"FUNDUS": 0, "NOT_FUNDUS": 0, "UNDETERMINED": 0}
    reason_counts: dict[str, int] = {}
    for r in records:
        gate_counts[r["gate"]] = gate_counts.get(r["gate"], 0) + 1
        if r["gate"] == "NOT_FUNDUS":
            key = r["gate_reason"].split("(")[0].strip()
            reason_counts[key] = reason_counts.get(key, 0) + 1

    quality_counts: dict[str, int] = {}
    for r in records:
        if r["quality"]:
            quality_counts[r["quality"]] = quality_counts.get(r["quality"], 0) + 1

    report = {
        "dataset": {
            "repo": args.repo if not args.parquet else os.path.abspath(args.parquet),
            "split": DEFAULT_PARQUET,
            "n_images": n,
            "label_distribution": {str(c): labels_l.count(c) for c in range(5)},
            "mode": args.mode,
            "model_backend": backend,
            "wall_seconds": wall_seconds,
        },
        "domain_gate": {
            **gate_counts,
            "coverage": round(len(kept_gated) / n, 4),
            "false_reject_rate": round(gate_counts["NOT_FUNDUS"] / n, 4),
            "reject_reasons": reason_counts,
        },
        "model_all_images": view(kept_all),
        "end_to_end_gated": {**view(kept_gated), "coverage": round(len(kept_gated) / n, 4)},
        "uncertainty_gate_released": {
            **view(kept_released),
            "released_fraction": round(len(kept_released) / n, 4),
            "abstained_fraction": round((n - len(kept_released)) / n, 4),
        },
        "note": (
            "Research benchmark on a public dataset; not a clinical claim. "
            "Referable = grade >= 2 (moderate NPDR and above). "
            "Uncertainty-gate 'released' = confident and unambiguous at the 0.70/0.15 gate."
        ),
    }
    if quality_counts:
        report["quality_gate"] = {
            **quality_counts,
            "pass_fraction": round(
                sum(v for k, v in quality_counts.items() if k != "BAD") / max(len(kept_gated), 1), 4
            ),
        }
    return report


def _print_report(report: dict, write_paths: tuple) -> None:
    gate = report["domain_gate"]
    print(
        f"\n== domain gate ==  coverage={gate['coverage']:.1%} "
        f"FRR={gate['false_reject_rate']:.1%} "
        f"{{FUNDUS: {gate['FUNDUS']}, NOT_FUNDUS: {gate['NOT_FUNDUS']}, "
        f"UNDETERMINED: {gate['UNDETERMINED']}}}"
    )
    if report.get("quality_gate"):
        q = report["quality_gate"]
        print(
            f"== quality gate ==  GOOD={q.get('GOOD', 0)} BORDERLINE={q.get('BORDERLINE', 0)} "
            f"BAD={q.get('BAD', 0)} pass={q.get('pass_fraction')}"
        )
    for key in ("model_all_images", "end_to_end_gated", "uncertainty_gate_released"):
        m = report[key]
        if not m.get("n"):
            print(f"== {key} ==  n=0")
            continue
        r = m["referable_dr"]
        print(
            f"== {key} == n={m['n']} acc={m['accuracy']:.3f} within1={m['within_one_accuracy']:.3f} "
            f"macroF1={m['macro_f1']} QWK={m['quadratic_weighted_kappa']:.3f} ECE={m.get('ece')}"
        )
        print(
            f"   referable: sens={r['sensitivity']} spec={r['specificity']} "
            f"ppv={r['ppv']} npv={r['npv']}"
        )
    json_path, csv_path = write_paths
    print(f"-> {json_path}" + (f"\n-> {csv_path}" if csv_path else ""))


def main() -> int:
    ap = argparse.ArgumentParser(description="Labeled fundus dataset evaluation for Drishti-AI.")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--parquet", default=None, help="Local parquet path (skips HF download).")
    ap.add_argument(
        "--limit", type=int, default=0, help="Evaluate only the first N images (0 = all)."
    )
    ap.add_argument(
        "--mode",
        choices=["model", "quality"],
        default="model",
        help="'model' = domain gate + DR classifier; 'quality' also runs Model 1.",
    )
    ap.add_argument(
        "--from-csv",
        default=None,
        help="Re-analyze an existing predictions CSV without re-running inference.",
    )
    ap.add_argument(
        "--out", default=os.path.join(PROJECT_ROOT, "results", "labeled_evaluation.json")
    )
    args = ap.parse_args()

    # Protect the canonical full-run artifacts: a limited or quality-only run
    # must not silently overwrite results/labeled_evaluation*.json|csv.
    default_out = os.path.join(PROJECT_ROOT, "results", "labeled_evaluation.json")
    if args.out == default_out and (args.mode == "quality" or args.limit):
        stem = f"labeled_evaluation_{args.mode}_{args.limit or 'full'}"
        args.out = os.path.join(PROJECT_ROOT, "results", f"{stem}.json")

    if args.from_csv:
        records = load_records_csv(args.from_csv)
        backend = "csv-replay"
        wall = 0.0
        print(f"replaying {len(records)} records from {args.from_csv}")
        report = build_report(records, args, backend, wall)
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=2)
        _print_report(report, write_paths=(args.out, None))
        return 0

    if args.parquet:
        ppath = args.parquet
    else:
        ppath = importlib.import_module("huggingface_hub").hf_hub_download(
            args.repo, DEFAULT_PARQUET, repo_type="dataset"
        )

    from PIL import Image

    from src.classification.classifier import DRClassifier
    from src.pipeline.confidence import ConfidenceEvaluator
    from src.quality.fundus_gate import build_fundus_gate

    labels = read_labels(ppath)
    if args.limit:
        # The parquet is sorted by label; a plain head() would yield an
        # all-grade-0 subsample. Stratify so --limit stays representative.
        keep = stratified_indices(labels, args.limit)
    else:
        keep = None
    n = len(keep) if keep is not None else len(labels)
    rows = iter_fundus_rows(ppath, keep)
    print(
        f"dataset={args.repo} parquet={os.path.basename(ppath)} n={n} mode={args.mode}", flush=True
    )

    gate = build_fundus_gate()
    clf = DRClassifier()
    print(f"model_backend={clf.get_backend()}", flush=True)
    if clf.get_backend() == "simulated":
        print(
            "[warn] classifier has NO real weights loaded; metrics below are FABRICATED.",
            flush=True,
        )
    elif clf.get_backend() != "keras":
        print(
            f"[info] measuring the shipped {clf.get_backend()} backend (not the legacy keras model).",
            flush=True,
        )
    conf_eval = ConfidenceEvaluator()
    checker = None
    if args.mode == "quality":
        from src.quality.checker import ImageQualityChecker

        checker = ImageQualityChecker()

    records = []
    t0 = time.time()
    for i, (blob, label) in enumerate(rows):
        img = np.asarray(Image.open(__import__("io").BytesIO(blob)).convert("RGB"))
        pil = Image.fromarray(img)
        decision = gate.evaluate(img)
        pred = clf.predict(pil)
        conf = conf_eval.evaluate(pred)
        quality_grade = ""
        if checker is not None:
            q = checker.assess_image(img, strict_mode=False)
            quality_grade = q.grade.value
        records.append(
            {
                "index": i,
                "label": label,
                "pred": pred.predicted_grade.value,
                "confidence": round(float(pred.confidence), 4),
                "top2_margin": round(float(pred.top2_margin), 4),
                "probabilities": ";".join(f"{p:.6f}" for p in (pred.probabilities or [])),
                "gate": decision.verdict.value,
                "gate_reason": decision.reason,
                "confident": conf.is_confident and not conf.is_ambiguous,
                "quality": quality_grade,
            }
        )
        # With ~8 GB total RAM (Brave et al. resident) release each decoded
        # image promptly instead of waiting for loop-scope GC.
        del img, pil
        if (i + 1) % 250 == 0:
            print(f"  {i + 1}/{n} ({time.time() - t0:.0f}s)", flush=True)

    report = build_report(records, args, clf.get_backend(), round(time.time() - t0, 1))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(report, fh, indent=2)

    csv_path = os.path.splitext(args.out)[0] + "_predictions.csv"
    with open(csv_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(records[0].keys()))
        writer.writeheader()
        writer.writerows(records)

    _print_report(report, write_paths=(args.out, csv_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
