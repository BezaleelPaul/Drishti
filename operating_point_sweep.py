"""Operating-point sweep for referable-DR detection.

Loads the per-image probability vectors saved by evaluate_labeled_dataset.py
(results/labeled_evaluation_predictions.csv) and sweeps thresholds on the
referable probability mass (p2 + p3 + p4), reporting the sensitivity /
specificity trade-off that threshold choice buys.

NOTE: thresholds are chosen on the SAME set they are reported on, so the
numbers are optimistic. The purpose is to document that a sensitivity lever
exists and to quantify the trade-off, not to ship a deployable threshold.
A real threshold must be calibrated on a held-out split.

Usage:
    python operating_point_sweep.py
    python operating_point_sweep.py --csv path/to/predictions.csv
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

DEFAULT_CSV = Path("results/labeled_evaluation_predictions.csv")
OUT_CSV = Path("results/operating_point_sweep.csv")
OUT_JSON = Path("results/operating_point_sweep.json")

REFERABLE_GRADES = (2, 3, 4)


def parse_probs(raw: str) -> list[float]:
    return [float(x) for x in raw.split(";") if x]


def referable_mass(probs: list[float]) -> float:
    return sum(probs[g] for g in REFERABLE_GRADES if g < len(probs))


def rates(tp: int, fp: int, tn: int, fn: int) -> dict[str, float]:
    sens = tp / (tp + fn) if tp + fn else 0.0
    spec = tn / (tn + fp) if tn + fp else 0.0
    ppv = tp / (tp + fp) if tp + fp else 0.0
    npv = tn / (tn + fn) if tn + fn else 0.0
    bal = (sens + spec) / 2
    total = tp + fp + tn + fn
    acc = (tp + tn) / total if total else 0.0
    return {
        "sens": round(sens, 4),
        "spec": round(spec, 4),
        "ppv": round(ppv, 4),
        "npv": round(npv, 4),
        "bal_acc": round(bal, 4),
        "binary_acc": round(acc, 4),
    }


def sweep(rows: list[dict]) -> tuple[list[dict], dict, dict, int]:
    labels = [int(r["label"]) for r in rows]
    masses = [referable_mass(parse_probs(r["probabilities"])) for r in rows]
    n = len(rows)

    thresholds = [round(t / 100, 2) for t in range(0, 101, 5)] + [
        0.03,
        0.07,
        0.10,
        0.15,
        0.25,
        0.35,
        0.45,
        0.55,
        0.65,
        0.75,
        0.85,
        0.95,
    ]
    results: list[dict] = []
    for t in sorted(set(thresholds)):
        tp = fp = tn = fn = 0
        for y, m in zip(labels, masses):
            pos = m >= t
            if y >= 2 and pos:
                tp += 1
            elif y < 2 and pos:
                fp += 1
            elif y < 2 and not pos:
                tn += 1
            else:
                fn += 1
        row = {"threshold": t, **rates(tp, fp, tn, fn), "tp": tp, "fp": fp, "tn": tn, "fn": fn}
        results.append(row)

    # Baseline: shipped policy = referable iff argmax >= 2
    tp = fp = tn = fn = 0
    for r in rows:
        pred = int(r["pred"])
        y = int(r["label"])
        pos = pred in REFERABLE_GRADES
        if y >= 2 and pos:
            tp += 1
        elif y < 2 and pos:
            fp += 1
        elif y < 2 and not pos:
            tn += 1
        else:
            fn += 1
    baseline = {
        "threshold": "argmax(=shipped)",
        **rates(tp, fp, tn, fn),
        "tp": tp,
        "fp": fp,
        "tn": tn,
        "fn": fn,
    }
    results.append(baseline)

    # Youden J optimum (illustrative, same-set)
    best = max(
        (r for r in results if r["threshold"] != "argmax(=shipped)"),
        key=lambda r: r["sens"] + r["spec"] - 1,
    )
    best["note"] = "youden_J_optimum"
    return results, baseline, best, n


def sensitivity_targets(results: list[dict]) -> list[dict]:
    out = []
    for target in (0.70, 0.80, 0.90, 0.95):
        eligible = [r for r in results if isinstance(r["threshold"], float) and r["sens"] >= target]
        if not eligible:
            continue
        best_spec = max(eligible, key=lambda r: r["spec"])
        out.append(
            {
                "target_sens": target,
                **{k: best_spec[k] for k in ("threshold", "sens", "spec", "ppv", "bal_acc")},
            }
        )
    return out


def split_holdout(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Stratified 50/50 calibration/test split, deterministic (seed 42)."""
    import random

    by_class: dict[int, list[dict]] = {}
    for r in rows:
        by_class.setdefault(int(r["label"]), []).append(r)
    calib: list[dict] = []
    test: list[dict] = []
    for label in sorted(by_class):
        group = list(by_class[label])
        random.Random(42 + label).shuffle(group)
        calib.extend(group[: len(group) // 2])
        test.extend(group[len(group) // 2 :])
    return calib, test


def holdout_analysis(rows: list[dict]) -> dict:
    """Tune the threshold on the calibration half, report once on the test half."""
    calib, test = split_holdout(rows)

    def at(sample: list[dict], t: float) -> dict:
        tp = fp = tn = fn = 0
        for r in sample:
            pos = referable_mass(parse_probs(r["probabilities"])) >= t
            y = int(r["label"]) >= 2
            if y and pos:
                tp += 1
            elif not y and pos:
                fp += 1
            elif not y and not pos:
                tn += 1
            else:
                fn += 1
        return {"threshold": t, **rates(tp, fp, tn, fn), "n": len(sample)}

    grid = [round(t / 100, 2) for t in range(0, 101)]
    t_star = max(grid, key=lambda t: (lambda m: m["sens"] + m["spec"] - 1)(at(calib, t)))

    # shipped argmax on the test half, for a fair before/after
    tp = fp = tn = fn = 0
    for r in test:
        pos = int(r["pred"]) in REFERABLE_GRADES
        y = int(r["label"]) >= 2
        if y and pos:
            tp += 1
        elif not y and pos:
            fp += 1
        elif not y and not pos:
            tn += 1
        else:
            fn += 1
    return {
        "split": "stratified 50/50, seed 42+label",
        "calibration_n": len(calib),
        "test_n": len(test),
        "t_star_calibrated_on_calib": t_star,
        "test_at_t_star": at(test, t_star),
        "test_shipped_argmax": {"threshold": "argmax", **rates(tp, fp, tn, fn)},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument(
        "--holdout",
        action="store_true",
        help="Tune the threshold on a calibration half and report on a held-out test half.",
    )
    args = parser.parse_args()

    with open(args.csv, newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("probabilities")]
    if not rows:
        raise SystemExit(
            f"no rows with probabilities in {args.csv} (re-run evaluate_labeled_dataset.py)"
        )

    results, baseline, youden, n = sweep(rows)
    targets = sensitivity_targets(results)

    with open(OUT_CSV, "w", newline="", encoding="utf-8") as fh:
        keys = list(dict.fromkeys(k for r in results for k in r))
        writer = csv.DictWriter(fh, fieldnames=keys)
        writer.writeheader()
        writer.writerows(results)

    summary = {"n": n, "shipped_argmax": baseline, "youden": youden, "sensitivity_targets": targets}
    if args.holdout:
        holdout = holdout_analysis(rows)
        summary["holdout"] = holdout

    OUT_JSON.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(f"n={n}  (referable positives={sum(1 for r in rows if int(r['label']) >= 2)})")
    print(f"\nshipped argmax policy : {baseline}")
    print(f"Youden-J optimum      : {youden}")
    print("\nbest spec at sensitivity target:")
    for t in targets:
        print(
            f"  sens>={t['target_sens']:.2f} -> threshold={t['threshold']:.2f} spec={t['spec']:.3f} ppv={t['ppv']:.3f}"
        )
    if args.holdout:
        h = summary["holdout"]
        print(
            f"\n=== hold-out ({h['split']}; calib n={h['calibration_n']}, test n={h['test_n']}) ==="
        )
        print(f"  t* tuned on calibration : {h['t_star_calibrated_on_calib']:.2f}")
        print(f"  test @ t*               : {h['test_at_t_star']}")
        print(f"  test shipped argmax     : {h['test_shipped_argmax']}")
    print(f"\n-> {OUT_CSV}\n-> {OUT_JSON}")


if __name__ == "__main__":
    main()
