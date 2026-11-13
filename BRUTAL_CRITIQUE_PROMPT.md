# BRUTAL PROJECT CRITIQUE — DRISHTI-AI (SIH 2026)

You are a senior medical AI engineer, a hackathon judge who has seen 200+ submissions, and a clinical safety officer. Your job is to DESTROY this project's weak points so we can fix them before presentation.

Be ruthless. Be specific. No flattery. No "good effort" nonsense.

---

## CONTEXT

This is a submission for SIH 2026, Problem Statement SIH26038 (MathWorks). The project is "Drishti-AI" — an AI-Assisted Diabetic Retinopathy Screening Pipeline for rural India. It uses a 2-model pipeline: Model 1 (Image Quality Gate) → Model 2 (DR Severity Classifier with Grad-CAM). It also includes a clinical risk engine, retinal segmentation, Simulink simulation, PDF/FHIR reporting, a FastAPI backend, and a Flutter mobile app (netra_ai_mobile).

The project repository is at: `C:\Users\bezal\Downloads\SIH HACKATHON`

The source code is in `src/`, app in `flutter_app/`, tests in `tests/`, docs in `docs/`, presentation in `presentation/`, Kaggle training notebooks in `kaggle/`, and MATLAB/Simulink in `matlab/`.

---

## YOUR TASK

Read the entire project — every source file, every doc, every test, the README, the presentation materials, the demo app — and then produce a BRUTAL critique covering:

### 1. TECHNICAL WEAKNESSES
- Are the ML models actually well-trained? What's the evidence?
- Is the quality gate actually reliable or just hardcoded thresholds?
- Does the Grad-CAM actually work or is it broken?
- Are the tests actually testing anything meaningful?
- Is the code production-quality or hackathon slop?
- Are there obvious bugs, race conditions, or failure modes?
- Is the Simulink model actually simulated or just described?
- Does the FHIR export actually produce valid FHIR?

### 2. CLINICAL SAFETY GAPS
- Would a real ophthalmologist trust this system?
- Are the ICMR guidelines actually correctly implemented?
- Is the confidence calibration real or fake?
- Could this system harm a patient?
- What happens when the model encounters something it's never seen?
- Are the "safety rules" actually enforced in code or just claimed in docs?

### 3. PRESENTATION & DEMO RISKS
- What questions will judges ask that we can't answer?
- What will make judges laugh at us?
- What looks impressive but is actually hollow?
 It also includes a clinical risk engine, retinal segmentation, Simulink simulation, PDF/FHIR reporting, and a Flutter app served by FastAPI.
- Is the demo just a pretty UI over a fragile pipeline?
- Can the demo actually run live without crashing?

### 4. HACKATHON STRATEGY FAILURES
- Are we solving the right problem or just building what we know?
- Are we over-engineering things judges don't care about?
- Are we under-engineering things judges will absolutely ask about?
- Is our 8-day sprint plan realistic or delusional?
- Who on the team is a bottleneck and why?

### 5. WHAT THE WINNING PROJECT HAS THAT WE DON'T
- **CPU vs GPU:** Does the pipeline actually run on a cheap laptop CPU (i3/4GB RAM) or does it silently require CUDA/GPU? Check if PyTorch is using CUDA anywhere. Check `final_model.keras` size — is 33MB model realistic for CPU inference?
- **OS Compatibility:** Does this actually run on Windows, Linux, AND macOS? Or did you only test on one OS? Check path handling (backslash vs forward slash), check if OpenCV headless is needed, check if `pytorch-grad-cam` even installs on all platforms.
- **Docker/Deployment:** Is there a Dockerfile? A `pyproject.toml`? A `Makefile`? Or is the only way to run this "clone the repo, hope Python works, hope dependencies install"?
- **Memory Footprint:** How much RAM does the pipeline consume? If a rural PHC has a ₹15,000 laptop with 4GB RAM and Chrome open, will this crash?
- Can a judge clone this repo and run it in under 60 seconds? If not, we lose.
- Is there a one-command setup (`make setup` or `docker compose up`)? If not, we look amateur.
- Code quality
- Demo impact

Then tell us: **What is the single most important thing we should fix in the next 48 hours?**

---
- DO test whether `pip install -r requirements.txt` actually succeeds cleanly on a fresh Python 3.12 install.
- DO check if the app crashes when camera hardware is switched mid-session.

Structure your critique as:


End with:
### TOP 5 THINGS TO FIX BEFORE PRESENTATION
2. ...
3. ...
4. ...


---

## BONUS: GENERATE THE FIXES

After the critique, also generate:

### 1. A working `Makefile` or `setup.sh` that does:
```bash
# One command to get the project running from fresh clone
python -m venv venv
source venv/bin/activate  # or venv\Scripts\activate on Windows
pip install -r requirements.txt
python -c "import torch; print('PyTorch OK:', torch.__version__)"
python -c "import fastapi; print('FastAPI OK:', fastapi.__version__)"
echo "Ready. Run: make run"
```
- Runs the FastAPI backend (uvicorn) and the Flutter mobile app
- Works on any Docker-capable machine
- Defines entry points
- Makes the project installable as a package

### 4. A hardware compatibility matrix:

| Hardware | CPU | RAM | GPU | OS | Status | Notes |
|----------|-----|-----|-----|----|--------|-------|
| Judge's laptop | i5 10th gen | 8GB | None | Windows 11 | TEST IT | |
| Rural PHC laptop | i3 8th gen | 4GB | None | Ubuntu 22.04 | TEST IT | |
| MacBook Air M1 | Apple M1 | 8GB | Metal | macOS 14 | TEST IT | |
| Kaggle notebook | Xeon | 13GB | T4 x2 | Ubuntu | TEST IT | |
| Raspberry Pi 4 | ARM Cortex | 4GB | None | Raspberry Pi OS | TEST IT | |
- CUDA unavailable → CPU fallback confirmed
- Flutter/LiteRT version mismatch → compatibility layer
