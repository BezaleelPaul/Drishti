# Hardware Portability, Edge Compatibility & Offline Guarantees

### SIH 2026 • ELYTRIVA / Netra-AI Screening System
**Architecture Defense for MathWorks SIH26038**

---

## 🎯 Executive Overview

A critical clinical failure mode of standard AI screening prototypes is dependency on expensive cloud GPU clusters and high-bandwidth internet. In rural India (Primary Health Centres, Sub-Centres, mobile screening vans), the real operating environment consists of:
- Entry-level laptops (Intel Core i3, AMD Ryzen 3, 4GB RAM)
- Intermittent 2G/3G or zero cellular internet connectivity
- Low-cost handheld fundus cameras (₹15,000 – ₹2,50,000) with optical aberrations, sensor noise, and varying fields-of-view

ELYTRIVA is architected from the ground up to **run 100% offline on consumer CPUs**, requiring **zero GPU acceleration** and maintaining sub-second latency.

---

## 💻 Hardware Compatibility Matrix

> **Status correction (2026-09-28):** "VERIFIED" below means **measured via `benchmark_latency.py` on PC-class
> hardware** (laptop/desktop/edge profiles). The ASHA tablet row is an *engineering target*, NOT yet measured —
> the mobile app currently performs analysis on a paired PC/edge workstation and syncs results opportunistically.
> On-phone inference (int8 TFLite on A53-class devices) is the active v1.2 migration target; budget ≤1.5 s
> end-to-end / ≤300 MB RSS is committed in `docs/TEAM_PLAN_NEXT_UPDATE.md`. Do not quote tablet latency as a
> measured fact until the device-matrix run (Phase E) posts numbers to `results/tflite_benchmark.json`.

| Hardware Tier | CPU / Specs | RAM | GPU | OS | Latency (E2E) | Status | Clinical Role |
|:---|:---|:---:|:---:|:---|:---:|:---:|:---|
| **Rural PHC Laptop** | Intel Core i3 (7th/8th Gen) | 4 GB | None (CPU) | Ubuntu / Win 10 | **< 180 ms** | **VERIFIED** | Primary screening workstation |
| **ASHA Field Tablet** | Quad-Core ARM Cortex A53 | 3 GB | None | Android 11+ | **< 220 ms** | **TARGET (v1.2, on-device TFLite)** | Door-to-door check-in & triage |
| **Judge's Laptop** | Intel Core i5 / i7 / Ryzen 5 | 8–16 GB | Any / None | Windows 11 | **< 110 ms** | **VERIFIED** | Evaluation & live demo |
| **MacBook Air M1/M2** | Apple Silicon M-series | 8 GB | Metal / CPU | macOS 14+ | **< 95 ms** | **VERIFIED** | Developer & specialist review |
| **Edge Micro-Server** | Raspberry Pi 4 / 5 | 4–8 GB | None | Raspberry Pi OS | **< 320 ms** | **VERIFIED** | Offline clinic edge appliance |

---

## 🔌 Camera Hardware Calibration Profiles

Unlike naive pipelines that apply identical thresholds across all optical instruments, ELYTRIVA provides dynamically calibrated presets in `src/quality/checker.py` and `api/routes/system.py`:

```
                    ┌─────────────────────────┐
                    │ Camera Hardware Profile │
                    └────────────┬────────────┘
         ┌───────────────────────┼───────────────────────┐
         ▼                       ▼                       ▼
  [ Forus 3nethra ]      [ Remidio FOP ]         [ Volk iNview ]
  • PHC Desktop Mydriatic • Smartphone Non-Mydriatic• Indirect Ophthalmoscopy
  • Blur Good: > 75.0     • Blur Good: > 65.0    • Blur Good: > 60.0
  • Brightness: 35 - 215  • Brightness: 32 - 225 • Brightness: 30 - 230
  • FOV Ratio: > 0.32     • FOV Ratio: > 0.30    • FOV Ratio: > 0.22
```

1. **Forus 3nethra classic (PHC Desktop)**: Higher optical resolution; tuned for strict focus standards.
2. **Remidio FOP (Smartphone Handheld)**: Accommodates minor LED reflection artifacts and smartphone lens barrel distortion.
3. **Volk iNview (Lens Attachment)**: Calibrated for smaller circular field-of-view ratio (>0.22) and optical condensation.
4. **Generic Fundus Camera (Default)**: Balanced conservative thresholds ensuring safe zero-leakage triage.

---

## ⚡ Non-Negotiable Edge Guarantees

### 1. 100% Zero-Telemetry Offline Operation
- **No Remote Model Downloads**: Pre-trained weights (`final_model.keras`, `diabetes_ml_model.joblib`) are packaged locally within the repository.
- **No Web Font or CDN Dependencies**: Offline styling and bundled assets in `flutter_app/assets/images`.
- **Local SQLite Audit Trail**: Screening records, doctor review queues, and patient demographics are persisted in `netra_ai.db`.

### 2. Lightweight Memory Footprint
- Peak RAM consumption during concurrent end-to-end inference (Quality Gate + EfficientNetB0 + Grad-CAM++ + Retinal Segmentation): **620 MB**.
- Easily fits within standard 4GB RAM machines with operating system overhead.

### 3. Graceful Fallbacks & Fault Tolerance
- If `torch` or `keras` are unavailable on restricted hardware, the pipeline falls back gracefully to deterministic calibrated heuristics without crashing.
- Unsupported image formats (e.g. corrupted files or empty streams) trigger defensive HTTP 400 validation instead of unhandled exceptions.
- Camera hardware switching mid-session recalculates quality gates instantly without requiring application restart.
