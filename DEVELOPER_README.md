# 🌐 Drishti-AI: Universal Developer & Deployment Guide

### Smart India Hackathon 2026 • Problem Statement SIH26038 (MathWorks)
**Complete Clinical Screening Platform (Python AI Pipeline • FastAPI Backend • Flutter Mobile App)**

> **Clinical Architecture Premise:**  
> Standard 5-class DR classification was proven by Google Health (Gulshan et al., 2016) and IDx-DR on curated hospital-grade tabletop cameras. **Drishti-AI operationalizes and democratizes this capability for rural Indian PHCs**: introducing Model 1 Quality Gating (preventing false diagnoses on ungradable handheld captures), sub-180ms CPU-only offline execution, quantitative CSME biomarker extraction, and district-scale telemedicine triage.


## 🚀 1-Click Quickstart (No Manual Setup Needed)

Whether you are on **Windows** or **macOS**, this repository includes automated, zero-configuration setup scripts that isolate all dependencies and prevent system errors.

### 🪟 If You Are on Windows:
1. **Double-click** `setup_windows.bat`  
   *(Automatically detects Python, creates `./venv`, installs dependencies, and runs verification).*
2. **Double-click** `run_windows.bat`  
   *(Presents an interactive launch menu for the FastAPI backend and Flutter app, verification, and API tests).*

### 🍎 If You Are on macOS (Apple Silicon or Intel):
1. Open **Terminal** (`Cmd + Space` → `Terminal`).
2. Navigate to the folder and run:
   ```bash
   chmod +x setup_mac.sh run_mac.sh
   ./setup_mac.sh
   ```
   *(Auto-detects M1/M2/M3/M4 or Intel, creates `./venv` to prevent PEP 668 errors, and verifies all 10 subsystems).*
3. Run `./run_mac.sh` to pick which application to launch.

### 🐳 If You Prefer Docker (Any OS):
```bash
export DRISHTI_API_KEYS='replace-with-a-long-random-key:operator'
docker compose up
```
Open **http://localhost:8000/app** in your browser.


## 📦 What Is Inside the Software Ecosystem

Drishti-AI consists of four integrated layers designed for rural tele-ophthalmology in India:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            FRONTEND INTERFACES                              │
├─────────────────────────────────────────┬───────────────────────────────────┤
│    📱 ASHA Mobile Client (Flutter)       │   🖥️ Central Doctor Console       │
│    - Door-to-door patient check-in      │   - 2-Model diagnostic screening  │
│    - Model 1 camera quality gate        │   - Grad-CAM++ visual attention   │
│    - Hindi audio guidance prompt        │   - Quantitative CSME biomarkers  │
│    - Bilingual SMS referral slip        │   - ABDM FHIR R4 & PDF Dossier    │
└────────────────────┬────────────────────┴─────────────────┬─────────────────┘
                     │                                      │
                     ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ⚡ FASTAPI REST BACKEND BRIDGE                         │
│   - http://localhost:8000/docs (Interactive Swagger Documentation)          │
│   - http://localhost:8000/app  (Pre-compiled Flutter Web App)               │
│   - /retinal/quality (Quality Triage) | /retinal/analyze (E2E Grading)      │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         🧠 CORE PYTHON AI PIPELINE                          │
│   1. Model 1 Quality Gate (Multi-scale Laplacian, illumination, FOV coverage)│
│   2. Model 2 DR Classifier (Fine-tuned EfficientNetB0 on APTOS 2019)        │
│   3. Grad-CAM++ Explainability Engine (<1.2s CPU execution)                 │
│   4. Retinal Segmentation (Optic Disc, Fovea, Vessel Tree, CSME risk)      │
│   5. Upstream Clinical Risk Engine (ICMR 2024 Asian-Indian BMI cutoffs)     │
│   6. Telemedicine Simulink Model (100k patients, 99.1% bandwidth saving)    │
└─────────────────────────────────────────────────────────────────────────────┘
```


## 📂 Complete Folder Structure Reference

```text
SIH HACKATHON/
│
├── 🚀 1-Click Launchers
│   ├── setup_windows.bat       # 1-Click installer for Windows (auto-venv + deps + test)
│   ├── run_windows.bat         # Interactive terminal launcher for Windows
│   ├── setup_mac.sh            # 1-Click installer for macOS (auto-detects M-Series/Intel)
│   ├── run_mac.sh              # Interactive terminal launcher for macOS
│   ├── Makefile                # Developer shortcuts (make setup, make test, make run)
│   ├── Dockerfile              # Production container build
│   └── docker-compose.yml      # Zero-configuration container runner
│
├── 🧠 Core AI Pipeline (`src/`)
│   ├── quality/                # Model 1: Image Quality Gate & triage engine
│   │   ├── checker.py          # Blur, illumination, contrast, FOV triage
│   │   └── enhancer.py         # Non-destructive CIELAB CLAHE enhancer
│   ├── classification/         # Model 2: DR Severity Classifier & Grad-CAM++
│   │   ├── classifier.py       # 5-class EfficientNetB0 inference engine
│   │   └── gradcam.py          # True gradient backpropagation attention heatmaps
│   ├── clinical_risk/          # Upstream population diabetes risk assessment
│   │   └── risk_model.py       # Random Forest model calibrated on ICMR cutoffs
│   ├── segmentation/           # MathWorks Req 2: Retinal Structure Segmentation
│   │   └── structure_segmenter.py # Optic Disc, Fovea, Vessel Tree, CSME risk
│   ├── simulation/             # MathWorks Req 5: Simulink 100k Queuing Simulation
│   │   └── telemedicine_sim.py # 99.1% bandwidth reduction discrete-event model
│   ├── reporting/              # Clinical reporting & ABDM export
│   │   ├── pdf_generator.py    # Hospital-grade printable A4 PDF screening dossier
│   │   └── fhir_exporter.py    # ABDM FHIR R4 DiagnosticReport (LOINC / SNOMED CT)
│   └── pipeline/               # Decision router & confidence engine
│       ├── router.py           # 11-node clinical decision flow router
│       ├── confidence.py       # Softmax margin evaluation & review escalation
│       └── schema.py           # Strict dataclass schemas
│
├── 🌐 Web & API Applications
│   └── api/                    # FastAPI Backend Bridge and Flutter host
│       ├── main.py             # FastAPI entry point (serves API & Flutter Web)
│       ├── database.py         # SQLite schema (patients, screenings, reviews)
│       ├── schemas.py          # Pydantic request/response validation
│       └── routes/             # REST endpoints (patients, risk, retinal, review)
│
├── 📱 Flutter Mobile / Tablet App (`flutter_app/`)
│   ├── lib/                    # Complete Dart source code
│   │   ├── main.dart           # App entry point, Material 3 healthcare theme
│   │   ├── models/             # Patient & Screening models
│   │   ├── services/           # ApiService with offline fallback
│   │   └── screens/            # 4 dedicated screens (Check-in, Quality, Results, Queue)
│   ├── build/web/              # Pre-compiled production WebAssembly/JS bundle
│   └── assets/images/          # Bundled clinical fundus test images
│
├── 📦 Pre-Trained Weights & External Toolboxes
│   ├── final_model.keras       # Fine-tuned EfficientNetB0 (33.4 MB)
│   ├── diabetes_ml_model.joblib# Pre-trained clinical risk model
│   └── external/               # Hugging Face & Berens Lab research assets
│
├── 🧪 Verification & Test Suites
│   ├── verify_complete_system.py # End-to-end benchmark of all 10 subsystems
│   ├── test_api_endpoints.py     # Comprehensive FastAPI endpoint test
│   ├── test_ml_pipeline_upgrade.py # Quality Gate & Grad-CAM++ test
│   ├── test_samples/             # Real clinical fundus images & test packs
│   └── tests/                    # Unit, integration, and edge-case tests
│
└── 📚 Guides & Documentation
    ├── DEVELOPER_README.md       # This universal developer guide
    ├── SETUP_MACOS.md            # Dedicated macOS installation guide
    ├── HARDWARE_COMPATIBILITY.md # Edge hardware portability & offline matrix
    ├── docs/ARCHITECTURE.md      # Detailed system architecture
    └── presentation/             # Official 8-slide PPT deck and pitch guides
```


## 🛠️ How to Develop & Test Each Component

### 1. Developing the Python AI Pipeline (`src/`)
All models and algorithms are modular and importable as standard Python packages:
```bash
# Activate virtual environment
# Windows:
venv\Scripts\activate
# Mac / Linux:
source venv/bin/activate

# Run verification suite (runs in <2 seconds on CPU)
python verify_complete_system.py
```

### 2. Developing the FastAPI Backend (`api/`)
```bash
# Run server with live auto-reload
python -m uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload

# Run automated API endpoint test suite
python test_api_endpoints.py
```
* **Swagger API Docs**: `http://localhost:8000/docs`
* **Flutter Web App via API**: `http://localhost:8000/app`

### 3. Developing the Flutter Mobile App (`flutter_app/`)
If you have the [Flutter SDK](https://flutter.dev) installed:
```bash
cd flutter_app

# Run static analysis (0 errors, 0 warnings)
dart analyze lib

# Run unit & widget tests
flutter test

# Run app in Chrome or macOS Native
flutter run -d chrome
```
*Rebuilding the Web Bundle*:
If you modify Dart code in `flutter_app/lib/` and want to update the pre-compiled version served by FastAPI:
```bash
cd flutter_app
flutter build web --release
```

## ❓ Cross-Platform Troubleshooting Matrix

| Problem | Operating System | Solution |
|---|---|---|
| `python was not found` | Windows | Install Python 3.10+ from python.org and check **"Add python.exe to PATH"**. |
| `error: externally-managed-environment` | macOS Sonoma / Sequoia | Run `./setup_mac.sh` which uses `./venv` to safely isolate packages. |
| `Address already in use: 8000` | Any | Free port 8000: Windows: `netstat -ano \| findstr :8000`, Mac: `lsof -ti :8000 \| xargs kill -9`. |
| `Flutter CLI not found` | Any | You don't need Flutter! Launch Option [2] in `run_windows.bat` or `run_mac.sh` to open the pre-built app at `http://localhost:8000/app`. |
| Script permission denied | macOS | Run `chmod +x setup_mac.sh run_mac.sh`. |


## 🏆 Presentation Quick-Pitch Checklist

When demonstrating Drishti-AI to evaluators or judges:
1. **Show Model 1 Rejection First**: Load `1_blurry_eye_retake.jpg`. Point out that the AI **refuses to diagnose** poor quality images and provides actionable distance guidance and audio feedback instead of generating a fake grade.
2. **Show Model 2 Diagnostic Grading & Grad-CAM++**: Load `2_clear_eye_normal.jpg` or `3_severe_eye_referral.jpg`. Demonstrate the high-speed Grad-CAM++ visual attention heatmap and CSME risk calculation.
3. **Show the Flutter workflow**: Show field check-in, quality gating, results, and tele-review in the Flutter app served by FastAPI.
4. **Show ABDM / Ayushman Bharat Compliance**: Download the clinical A4 PDF dossier and ABDM FHIR R4 JSON bundle.
