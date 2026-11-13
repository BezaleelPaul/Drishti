# Drishti — Production Clinical Diabetic Retinopathy Diagnostic Platform
### Autonomous Clinical AI Retinal Screening Platform

Drishti is a self-contained, offline-first **Clinical Production Package** for autonomous Diabetic Retinopathy (DR) screening and triage. It includes calibrated deep learning weights, cross-platform standalone binaries, presentation materials, 10-subsystem clinical verification harnesses, and FastAPI backend services.

---

## 📁 Repository Structure

```
Drishti/
├── binaries/                       # Standalone binaries (distributed via GitHub Releases v1.7.0)
│   ├── drishti_mobile_v1.7.0.apk  # Android release APK (offline INT8 edge engine)
│   ├── drishti_windows_v1.7.0.zip # Windows desktop clinic bundle
│   ├── drishti_linux_v1.7.0.tar.gz# Linux workstation clinic bundle
│   ├── drishti_macos_v1.7.0.zip   # macOS clinic application bundle
│   └── drishti_ios_unsigned_v1.7.0.zip # iOS release bundle
│
├── models/                         # Calibrated clinical & edge model weights
│   ├── dr_efficientnet_b0_tuned_int8.tflite # 5.08 MB INT8 edge model (96.28% recall)
│   ├── dr_efficientnet_b0_tuned_fp32.tflite # 16 MB FP32 baseline model
│   ├── final_model.keras           # Full 52 MB Keras deep clinical model
│   ├── efficientnet_b0_regression_512px.onnx # DRDetect Ordinal server model
│   └── clinical_scorecard.json     # Audited Kaggle GPU validation metrics (QWK 0.8739)
│
├── docs/                           # Comprehensive clinical, architectural & regulatory docs
│   ├── CLINICAL_BRUTAL_TEST_REPORT.md # 100-patient brutal real-world clinical test
│   ├── REAL_WORLD_READINESS_AUDIT.md  # SaMD clinical audit & regulatory defense
│   ├── ARCHITECTURE.md             # System architecture & data flow
│   ├── DECISION_FLOW.md            # Clinical triage decision trees & gating logic
│   └── METRICS_AND_EVALUATION.md   # Statistical validation & inter-grader concordance
│
├── presentation/                   # Complete judge defense & presentation suite
│   ├── DRISHTI_Presentation.pptx  # 15-slide widescreen PowerPoint deck
│   ├── OFFLINE_DEMO_BACKUP.html    # Interactive browser dashboard (runs with no Wi-Fi)
│   ├── JUDGES_QA_DEFENSE.md        # Winning defense script for hard technical questions
│   ├── PITCH_AND_SLIDES_OUTLINE.md # 30-sec pitch, 3-min pitch, and slide notes
│   ├── final_report.md             # Comprehensive engineering & clinical report
│   ├── RELEASE_NOTES_v1.7.0.md     # Official v1.7.0 release notes
│   └── rendered_slides/            # High-res PNG slide previews
│
├── server/                         # Runnable FastAPI screening server & test harness
│   ├── src/                        # Complete clinical pipeline (Stages 0-5)
│   ├── api/                        # FastAPI REST endpoints
│   ├── test_samples/               # Clinical fundus test images & adversarial samples
│   ├── demo_rehearsal.py           # Automated end-to-end rehearsal (23 assertions)
│   ├── verify_complete_system.py   # 10-subsystem audit test suite
│   └── requirements.txt            # Python dependencies
│
├── start_server.sh                 # One-click start for screening API (:8000)
├── verify_system.sh                # One-click run of the 10-subsystem verification
├── run_rehearsal.sh                # One-click run of the end-to-end live rehearsal
└── open_offline_demo.sh            # Opens the interactive visual demo in browser
```

---

## 📊 Audited Clinical Performance (Holdout Set: 731 Fundus Images)

| Clinical Metric | Production Value | Benchmark / Standard | Clinical Significance |
| :--- | :---: | :---: | :---: |
| **Referable Sensitivity (Recall)** | **`96.28%`** | $\ge 90.0\%$ | Missing only 11 out of 296 sick patients |
| **Referable Specificity** | **`91.03%`** | $\ge 80.0\%$ | Exceeds British Diabetic Association $\ge 80\%$ standard |
| **Negative Predictive Value (NPV)** | **`97.30%`** | $\ge 95.0\%$ | Frontline confidence: Non-referable diagnoses are reliable |
| **Positive Predictive Value (PPV)** | **`87.96%`** | High | Prevents flooding secondary ophthalmology hospitals |
| **Quadratic Weighted Kappa (QWK)** | **`0.8739`** | $\ge 0.80$ | **Near-Perfect Agreement** with human retinal specialists |
| **Top-1 Multi-Class Accuracy** | **`80.03%`** | Baseline | Balanced multi-class grading across all 5 ICDR stages |
| **Calibrated Decision Cut-Point ($t^*$)** | **`0.6450`** | — | Calibrated on held-out validation cohort |
| **Edge Quantized Model Footprint** | **`5.08 MB`** | $< 10.0$ MB | Sub-150ms on-device inference without internet |
| **Hospital Safety Gate Verdict** | **`PASSED`** | Gate Pass | Ready for frontline clinical screening deployment |

---

## 🚀 Quick-Start Commands

### 1. Run 10-Subsystem System Audit
```bash
./verify_system.sh
```
*Verifies all 10 clinical modules: Risk Engine, Model 1 Quality Gate, Adaptive CLAHE, Biomarker Segmentation, DR Classification, Grad-CAM, Simulink 100k Model, Hospital PDF, ABDM FHIR R4, Zero-Leakage.*

### 2. Run Automated Live Demo Rehearsal
```bash
./run_rehearsal.sh
```
*Boots the live server, executes a full patient screening workflow (registration -> diabetes risk -> image quality -> 5-class DR analysis -> PDF report -> adversarial attack rejection -> review queue sync), and asserts 23/23 clinical checks pass.*

### 3. Start Screening API Server
```bash
./start_server.sh
```
*Launches FastAPI at `http://127.0.0.1:8000`. Interactive Swagger docs available at `http://127.0.0.1:8000/docs`.*

### 4. Open Offline Visual Presentation Demo
```bash
./open_offline_demo.sh
```
*Opens `presentation/OFFLINE_DEMO_BACKUP.html` in your default browser. Runs completely offline without internet or backend dependencies.*

---

## 📱 Cross-Platform Standalone Downloads (Release v1.7.1)

Pre-built binaries are packaged and downloadable from [GitHub Releases](https://github.com/BezaleelPaul/Drishti/releases):
- **Android:** `drishti_mobile_v1.7.1.apk` — Sideload onto any Android phone or tablet (dual v2/v3 signed, bundled offline INT8 model).
- **Windows:** `drishti_windows_v1.7.1.zip` — Extract and run `drishti.exe`.
- **Linux:** `drishti_linux_v1.7.1.tar.gz` — Extract and run `./bundle/drishti`.
- **macOS:** `drishti_macos_v1.7.1.zip` — Extract and drag `Drishti.app` to `/Applications`. Run `xattr -cr /Applications/Drishti.app` to clear browser quarantine.
- **iOS:** `drishti_ios_unsigned_v1.7.1.zip` — Unsigned iOS release archive for sideloading / TestFlight.
