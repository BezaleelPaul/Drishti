# Section 12 Experimental Evaluation: A/B/C Comparison

_Evaluation backend: Model 2 ran in `keras` mode on a seeded synthetic-gradient
cohort (150 images, seed 42). Synthetic images carry no real DR lesions, so the
sensitivity/specificity rows below measure cohort behavior, not clinical accuracy.
The architectural claim of this experiment is the forced-prediction rate
(100% → 0% by construction of the quality gate), which holds on any backend.
Real-lesion validation belongs on an APTOS holdout with trained weights._

| Evaluation Metric | Arm A: Direct Baseline (No Gate) | Arm B & C: Our Proposed Pipeline | Clinical Significance |
|---|:---:|:---:|---|
| **Forced Predictions on Ungradable Images** | **100.0%** | **0.0%** | Prevents giving patients confident fake grades on blurry/corrupt images |
| **Referable DR Sensitivity (Reliable Images)** | Unreliable | **0.0%** | Synthetic-cohort behavior only — not a clinical accuracy claim |
| **Referable DR Specificity** | Unreliable | **100.0%** | Synthetic-cohort behavior only — not a clinical accuracy claim |
| **Screening Recapture / Abstention Rate** | 0.0% (Blind) | **20.7%** | Bounded field recapture overhead (< 20% target) |
| **Total Human Review Escalation Rate** | 0.0% (Silent Failure) | **79.3%** | Safe two-tier human safety net for ambiguous cases |
