# Evaluation Metrics and Experimental Design (Sections 12 & 13)

## 1. Metric Suite

### Model 1: Image Quality Assessment
- **Class-wise Precision and Recall:** Reported separately for Good, Borderline, and Bad.
- **Asymmetric Error Rates:**
  - **Bad → Good Error Rate (Safety-critical):** Letting a bad image pass to Model 2 must be minimized.
  - **Good → Bad Error Rate (Efficiency):** Unnecessarily rejecting a good image increases screening burden.

### Model 2: DR Severity Classification
- **Quadratic-Weighted Kappa (QWK):** Standard international DR competition metric; penalizes multi-grade misclassifications heavily.
- **Per-Class Sensitivity & Specificity:** Specifically monitoring minority classes (Severe NPDR, Proliferative DR).
- **Referable DR (Grade ≥ 2):** Sensitivity, Specificity, PPV, and NPV at chosen clinical operating threshold.

### Pipeline Operational Safety Metrics
- **Forced-Prediction Rate:** % of ungradable images forced into a DR grade (Baseline vs. Proposed).
- **Recapture Rate:** % of captured images requiring re-take.
- **Repeated Failure Rate:** % of cases hitting the 2-recapture hard cap.
- **Human Review Rate:** % of total cases escalated to clinician or operator.

---

## 2. A/B/C Research Experiment (Section 12)

| Arm | Flow Description | Experimental Purpose |
|---|---|---|
| **Arm A (Baseline)** | Image → Model 2 directly (no quality gate) | Demonstrates the real-world danger of forcing ungradable images into a disease classifier |
| **Arm B (Proposed)** | Image → Model 1 → Reassessment → Model 2 → Confidence → Grad-CAM | Proves reduction in forced predictions and improvement in effective sensitivity |
| **Arm C (Proposed + HR)** | Full pipeline with terminal human review active | Evaluates the fully deployable clinical screening workflow |
