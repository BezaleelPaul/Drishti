# 🧪 Team Verification Test Guide

This folder contains pre-packaged test cases to verify credibility across your team.

---

## Folder 1: `01_real_clinical_fundus/`
- **What it is:** Real-world retinal fundus photographs from hospital screenings (Berens Lab / DRIMDB).
- **Who tests it:** **Bezaleel & Akshay**
- **Expected Result:**
  - Image Quality Gate (Model 1): **`GOOD` (Reliable Original Image)**
  - Model 2: Outputs 5-class DR probability vector and Grad-CAM attention overlay.

---

## Folder 2: `02_quality_failures_and_edge_cases/`
- **What it is:** Challenging field conditions (severe camera glare, extreme underexposure, heavy motion blur).
- **Who tests it:** **Madhu**
- **Expected Result:**
  - Image Quality Gate: **`BAD`**
  - DR Prediction: **`Not generated`** (Strictly blocked!).
  - Action: Prompt to recapture image with reason code (`Severe blur`, `Inadequate illumination`, or `Severe glare`).

---

## Folder 3: `03_adversarial_non_fundus/`
- **What it is:** Adversarial non-retinal inputs (blue photos, flat surfaces, or random images).
- **Who tests it:** **Madhu**
- **Expected Result:**
  - Color profile & retinal mask verification halts the image: **`BAD`**.
  - Reason: `Non-fundus or corrupt image file`.
  - **Zero leakage** into disease grading.
- **Fixtures:** `external_*` are real photographs downloaded from Wikimedia
  Commons (faces, selfie, receipt, desk, landscape, desktop screenshot, retina
  illustration, segmentation/crop overlays — see `ATTRIBUTION.md`).
  `historical_api_upload_*` are two inputs that really went through
  `/retinal/analyze`; both must now stop at the domain gate.
- **Automated:** `tests/red_team/test_corpus_sweep.py` sweeps every scan test
  case in this folder **and every other image in the repo** and asserts no
  non-retinal input ever produces a DR (diabetes) prediction.

---

## Folder 4: `04_section24_demo_scenarios/`
- **What it is:** The official 4 demo cases from Section 24 of the Approved Specification.
- **Who tests it:** **Adithya & Team**
  1. `scenario_1_good.jpg`: Clean capture $\rightarrow$ Normal/Graded $\rightarrow$ Grad-CAM.
  2. `scenario_2_bad.jpg`: Fails quality $\rightarrow$ immediate recapture request.
  3. `scenario_3_borderline.jpg`: Marginal quality $\rightarrow$ enters reassessment.
  4. `scenario_4_uncertain.jpg`: Graded case $\rightarrow$ triggers **mandatory human review** due to low margin or high risk.

---

## How to Test in the Browser:
1. Start the API with `make run`.
2. Open the Flutter app at **`http://localhost:8000/app`**.
3. Use the screening flow with any image from these folders and observe the decision flow.
