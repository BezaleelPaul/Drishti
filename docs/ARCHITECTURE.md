# AI-Assisted Diabetic Retinopathy Screening: Architecture Specification

## 1. System Overview

This architecture implements a **two-model, human-in-the-loop screening pipeline** designed for field deployment (community camps, rural Primary Health Centres, screening vans). The central design principle is:
> **The AI must know when it cannot answer.** An ungradable retinal fundus image must never be silently forced into a disease prediction.

```
                  ┌──────────────────────┐
                  │ 1. Raw Fundus Image  │
                  └──────────┬───────────┘
                             │
                  ┌──────────▼───────────┐
                  │ 2. Image Quality Gate│ (Model 1)
                  └─────┬────┬─────┬─────┘
           Good (3a)    │    │ (3b) Borderline
        ┌───────────────┘    │     └──────────────┐
        │                    │ (3c) Bad           ▼
        │                    ▼             ┌──────────────┐
        │             ┌──────────────┐     │4.Reassessment│
        │             │  Recapture   │     └──────┬───────┘
        │             │ (Cap: 2)     │            │
        │             └──────┬───────┘     ┌──────┴───────┐
        │                    │             │5. Unreliable?│
        │                    │             └──┬────────┬──┘
        │                    │          No (5-No)     │ Yes (5-Yes)
        │                    │                │       ▼
        │                    │                │ ┌──────────────┐
        │                    │                │ │Recapture / HR│
        │                    │                │ └──────────────┘
        ▼                    ▼                ▼
 ┌──────────────┐     ┌──────────────┐ ┌──────────────┐
 │6. Reliable   │◄────┴──────────────┴─┤  Terminal    │
 │Original Image│                      │ Human Review │ (Node 11)
 └──────┬───────┘                      │ - Operator   │
        │                              │ - Clinician  │
 ┌──────▼───────┐                      └──────▲───────┘
 │7. DR Model   │ (Model 2)                   │
 └──────┬───────┘                             │
        │                                     │
 ┌──────▼───────┐                             │
 │8. Confidence │──────[Low Conf / High-Risk]─┘
 │  Uncertainty │
 └──────┬───────┘
        │
 ┌──────▼───────┐
 │9. Grad-CAM   │
 └──────┬───────┘
        │
 ┌──────▼───────┐
 │10. Screening │
 │    Result    │
 └──────────────┘
```

---

## 2. Locked Decisions

| Decision | Specification |
|---|---|
| **Number of AI Models** | Exactly 2: Model 1 (Quality Gate), Model 2 (DR Severity Classifier) |
| **Enhancement Model** | **Permanently removed.** Replaced by non-destructive Reassessment / Recapture. |
| **Borderline Images** | Reassessment with stricter criteria → if still marginal, escalated to recapture / human review. |
| **Bad Images** | Immediate rejection and recapture request with specific failure reason code. |
| **Good Images** | Proceed directly to DR grading holding unaltered original pixels. |
| **Non-Destructive Processing** | No CLAHE, sharpening, denoising, or generative enhancement applied at runtime (Section 20). |
| **Recapture Cap** | Hard cap of 2 recaptures per patient session to prevent infinite cycling (Section 5/7). |
| **Explainability** | Grad-CAM overlaid on final convolutional layer of Model 2 with explicit claim boundaries (Section 8). |
| **Human Review** | Terminal safety layer with two distinct entry points (Operator-level vs Clinical-level). |

---

## 3. Two-Model Separation

- **Model 1 (Quality Gate):** Answers *"Can we trust this image?"*
  - Native deep ensemble (`fundus_image_toolbox`) + dynamic contour circular ROI + multi-scale feature fusion ($S_{\text{blur}}, S_{\text{illum}}, S_{\text{contrast}}, S_{\text{fov}}$).
  - Continuous ML Quality Score $[0.0, 1.0]$ with 3-tier clinical calibration: Good ($\ge 0.70$), Borderline ($0.38 - 0.70$), Bad ($< 0.38$).
  - Graceful multi-scale CPU fallback for 100% offline edge deployment.
- **Model 2 (DR Classifier):** Answers *"What DR severity does this trustworthy image show?"*
  - Fine-tuned **EfficientNetB0** (`final_model.keras`, 33.4 MB) trained on APTOS 2019 Blindness Detection.
  - 5 classes: No DR (0), Mild NPDR (1), Moderate NPDR (2), Severe NPDR (3), Proliferative DR (4).
  - Referable DR: Grade ≥ 2.
  - **Explainability:** Exact gradient backpropagation via **Grad-CAM++** using higher-order partial derivatives ($\partial^2 y^c / \partial (A^k)^2$ and $\partial^3 y^c / \partial (A^k)^3$) to isolate scattered retinal micro-lesions.
