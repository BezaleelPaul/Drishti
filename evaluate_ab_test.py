"""
A/B/C Research Experiment & Safety Evaluation Script.
Implements Section 12 & 13 of the Approved Specification:
- Arm A (Baseline): Direct Image -> Model 2 classification (no quality gate)
- Arm B (Proposed): Quality Gate (Model 1) -> Reliable Image -> Model 2 -> Grad-CAM
- Arm C (Full Deployable): Arm B + Dual-Tier Human-in-the-loop escalation
"""

import json
import os

import numpy as np
import pandas as pd
from sklearn.metrics import confusion_matrix

from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import QualityGrade
from src.synthetic_fixtures import create_synthetic_fundus_image


def generate_evaluation_dataset(n_samples: int = 150, seed: int = 42):
    """
    Generates a synthetic clinical evaluation cohort representing field conditions:
    - 65% Good quality images (Grades 0 to 4)
    - 15% Borderline images (marginal focus/contrast)
    - 20% Bad images (severe blur, underexposed, non-fundus)
    """
    rng = np.random.RandomState(seed)
    dataset = []

    for i in range(n_samples):
        # Sample quality category
        p = rng.rand()
        if p < 0.65:
            q_category = "GOOD"
            img = create_synthetic_fundus_image()
            true_grade = int(rng.choice([0, 1, 2, 3, 4], p=[0.45, 0.20, 0.20, 0.10, 0.05]))
        elif p < 0.80:
            q_category = "BORDERLINE"
            # Marginal brightness/blur
            shift = float(rng.uniform(-35, -20))
            img = create_synthetic_fundus_image(brightness_shift=shift)
            true_grade = int(rng.choice([0, 1, 2, 3, 4], p=[0.40, 0.25, 0.20, 0.10, 0.05]))
        else:
            q_category = "BAD"
            # Severe underexposure or non-fundus (seeded: reproducible runs)
            if rng.rand() < 0.7:
                img = create_synthetic_fundus_image(brightness_shift=-180.0)
            else:
                img = create_synthetic_fundus_image(is_non_fundus=True, seed=seed + i)
            true_grade = -1 # Ungradable ground truth

        dataset.append({
            "id": f"IMG_{i:04d}",
            "image": img,
            "true_quality": q_category,
            "true_grade": true_grade,
        })
    return dataset


def run_ab_experiment():
    print("=" * 70)
    print("RUNNING SECTION 12 A/B/C RESEARCH EXPERIMENT")
    print("Direct Classification Baseline (Arm A) vs. Reliability-Gated (Arm B & C)")
    print("=" * 70)

    dataset = generate_evaluation_dataset(n_samples=150, seed=42)
    router = ScreeningPipelineRouter()
    classifier = router.dr_classifier
    eval_backend = classifier.get_backend()
    print(f"Model 2 evaluation backend: {eval_backend}")

    # Tracking Metrics
    # Arm A: Direct to Model 2
    arm_a_preds = []
    arm_a_forced_on_bad = 0
    arm_b_forced_on_bad = 0

    # Arm B: Proposed Quality-Gated Pipeline
    arm_b_accepted = 0
    arm_b_rejected = 0
    arm_b_preds = []
    arm_b_targets = []

    # Arm C: Proposed + Human Review
    arm_c_escalated_operator = 0
    arm_c_escalated_clinician = 0

    bad_count = sum(1 for d in dataset if d["true_quality"] == "BAD")
    good_count = sum(1 for d in dataset if d["true_quality"] in ("GOOD", "BORDERLINE"))

    for d in dataset:
        img = d["image"]
        true_g = d["true_grade"]
        is_bad = (d["true_quality"] == "BAD")

        try:
            # ---------------------------------------------------------
            # ARM A (BASELINE): Direct to Classifier
            # ---------------------------------------------------------
            raw_res = classifier.predict(img)
            arm_a_preds.append(raw_res.predicted_grade.value)
            if is_bad:
                # Baseline forcibly predicted a DR grade on an ungradable image!
                arm_a_forced_on_bad += 1

            # ---------------------------------------------------------
            # ARM B & C: Proposed Quality-Gated Pipeline
            # ---------------------------------------------------------
            record = router.process_image(img, recapture_attempt_count=0)
        except Exception as e:  # noqa: BLE001 - one bad sample must not abort the batch
            # One bad sample must not abort the whole 150-sample run.
            print(f"  [warn] sample {d['id']} errored ({e}); counted as rejected.")
            arm_b_rejected += 1
            continue

        if record.quality_grade == QualityGrade.BAD or record.dr_prediction is None:
            arm_b_rejected += 1
            if is_bad and record.dr_prediction is not None:
                # Gate leak: a grade escaped on a truly ungradable image.
                arm_b_forced_on_bad += 1
            if record.human_review_required:
                arm_c_escalated_operator += 1
        else:
            arm_b_accepted += 1
            arm_b_preds.append(record.dr_prediction.predicted_grade.value)
            arm_b_targets.append(true_g)

            if record.human_review_required:
                arm_c_escalated_clinician += 1

    # Metric Calculations (all guarded: n_samples=0 must not ZeroDivisionError)
    forced_pred_rate_arm_a = (arm_a_forced_on_bad / bad_count) * 100.0 if bad_count else 0
    # Measured, not asserted: counts grades that escaped the gate on BAD images.
    forced_pred_rate_arm_b = (arm_b_forced_on_bad / bad_count) * 100.0 if bad_count else 0.0

    recapture_rate = (arm_b_rejected / len(dataset)) * 100.0 if dataset else 0.0
    total_human_review_rate = ((arm_c_escalated_operator + arm_c_escalated_clinician) / len(dataset)) * 100.0 if dataset else 0.0

    # Referable DR Sensitivity on certified reliable images.
    # labels=[0,1] forces a 2x2 matrix even for single-class cohorts, so
    # tn/fp/fn/tp can never be silently swapped by sklearn's label inference.
    referable_true = [1 if t >= 2 else 0 for t in arm_b_targets]
    referable_pred = [1 if p >= 2 else 0 for p in arm_b_preds]
    if referable_true:
        cm = confusion_matrix(referable_true, referable_pred, labels=[0, 1])
        tn, fp, fn, tp = (int(v) for v in cm.ravel())
    else:
        tn = fp = fn = tp = 0
    # Degenerate single-class cohorts cannot yield sensitivity/specificity:
    # report n/a instead of a misleading perfect 100%.
    sensitivity = (tp / (tp + fn)) * 100.0 if (tp + fn) > 0 else None
    specificity = (tn / (tn + fp)) * 100.0 if (tn + fp) > 0 else None

    def _pct(value):
        return f"{value:.1f}%" if value is not None else "n/a (degenerate cohort)"

    # Output Summary Table
    print("\n" + "=" * 70)
    print("EXPERIMENTAL EVALUATION RESULTS (A/B/C COMPARISON)")
    print("=" * 70)
    print(f"Total Evaluated Images:           {len(dataset)}")
    print(f"  - Truly Usable Retinal Images:  {good_count}")
    print(f"  - Truly Ungradable/Bad Images:  {bad_count}\n")

    results_table = {
        "Metric": [
            "Forced Prediction Rate on Bad Images",
            "Referable DR Sensitivity (Reliable Images)",
            "Referable DR Specificity (Reliable Images)",
            "Screening Recapture / Re-assessment Rate",
            "Human Review Escalation Rate (Safety Net)",
        ],
        "Arm A (Direct Baseline)": [
            f"{forced_pred_rate_arm_a:.1f}% (CRITICAL FAILURE)",
            "Unreliable (Conflated)",
            "Unreliable (Conflated)",
            "0.0% (Ignores Quality)",
            "0.0% (No Human Safety Layer)",
        ],
        "Arm B & C (Our Proposed System)": [
            f"{forced_pred_rate_arm_b:.1f}%"
            + (" (100% BLOCKED)" if arm_b_forced_on_bad == 0 else " (GATE LEAK — INVESTIGATE)"),
            _pct(sensitivity),
            _pct(specificity),
            f"{recapture_rate:.1f}%",
            f"{total_human_review_rate:.1f}% (Bounded)",
        ]
    }
    df_results = pd.DataFrame(results_table)
    print(df_results.to_string(index=False))

    # Save to disk (anchored to repo root so CWD cannot redirect/overwrite elsewhere)
    PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(PROJECT_ROOT, "results"), exist_ok=True)
    os.makedirs(os.path.join(PROJECT_ROOT, "docs"), exist_ok=True)

    def _atomic_write(path: str, content: str) -> None:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(content)
        os.replace(tmp, path)

    _atomic_write(
        os.path.join(PROJECT_ROOT, "results/ab_comparison_metrics.json"),
        json.dumps({
            "total_samples": len(dataset),
            "model2_backend": eval_backend,
            "note": "Synthetic-gradient cohort; sensitivity/specificity are cohort-behavior metrics, not clinical accuracy claims.",
            "forced_pred_rate_baseline": forced_pred_rate_arm_a,
            "forced_pred_rate_proposed": forced_pred_rate_arm_b,
            "sensitivity_referable_dr": sensitivity,
            "specificity_referable_dr": specificity,
            "recapture_rate": recapture_rate,
            "human_review_rate": total_human_review_rate,
        }, indent=2),
    )

    # Save markdown summary for docs and slides
    md_content = f"""# Section 12 Experimental Evaluation: A/B/C Comparison

_Evaluation backend: Model 2 ran in `{eval_backend}` mode on a seeded synthetic-gradient
cohort (150 images, seed 42). Synthetic images carry no real DR lesions, so the
sensitivity/specificity rows below measure cohort behavior, not clinical accuracy.
The architectural claim of this experiment is the forced-prediction rate
(100% → 0% by construction of the quality gate), which holds on any backend.
Real-lesion validation belongs on an APTOS holdout with trained weights._

| Evaluation Metric | Arm A: Direct Baseline (No Gate) | Arm B & C: Our Proposed Pipeline | Clinical Significance |
|---|:---:|:---:|---|
| **Forced Predictions on Ungradable Images** | **{forced_pred_rate_arm_a:.1f}%** | **{forced_pred_rate_arm_b:.1f}%** | Prevents giving patients confident fake grades on blurry/corrupt images |
| **Referable DR Sensitivity (Reliable Images)** | Unreliable | **{_pct(sensitivity)}** | Synthetic-cohort behavior only — not a clinical accuracy claim |
| **Referable DR Specificity** | Unreliable | **{_pct(specificity)}** | Synthetic-cohort behavior only — not a clinical accuracy claim |
| **Screening Recapture / Abstention Rate** | 0.0% (Blind) | **{recapture_rate:.1f}%** | Bounded field recapture overhead (< 20% target) |
| **Total Human Review Escalation Rate** | 0.0% (Silent Failure) | **{total_human_review_rate:.1f}%** | Safe two-tier human safety net for ambiguous cases |
"""
    _atomic_write(os.path.join(PROJECT_ROOT, "docs/AB_EXPERIMENT_RESULTS.md"), md_content)

    print("\nSaved experiment results to results/ab_comparison_metrics.json and docs/AB_EXPERIMENT_RESULTS.md\n")


if __name__ == "__main__":
    run_ab_experiment()
