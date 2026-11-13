# Dataset Strategy (Section 11)

This document specifies the dataset roles and usage across the project pipeline.

| Dataset | Primary Use | Role in Pipeline | Notes |
|---|---|---|---|
| **APTOS 2019 Blindness Detection** | Model 2 Training & Evaluation | Primary 5-class DR classifier training | ~3,662 labeled images. Skewed toward Grade 0 (~49%). Requires class-weighted loss. |
| **EyePACS / DeepDRiD / In-house** | Model 1 Quality Gate | Good / Borderline / Bad classification | Requires explicit quality labels (blur, illumination, contrast, artifacts). |
| **IDRiD** | Grad-CAM Explainability Review | Qualitative sanity check | Used for qualitative comparison against microaneurysm & hemorrhage ground truth. |
| **Messidor-2** | External Generalization (Optional) | Out-of-distribution testing | Demonstrates cross-camera and population robustness without claiming clinical approval. |
