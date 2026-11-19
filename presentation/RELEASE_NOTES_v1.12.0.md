# Drishti v1.12.0 Release Notes: Clinical Workplace Ergonomics & Operator Comfort

**Release Date:** November 19, 2026  
**Tag:** `v1.12.0`  
**Git Commit Target:** `main`

---

## 🌟 What's New in v1.12.0

### 1. Clinical Darkroom HUD Modes (`Ruby 650nm` & `Amber 590nm`)
- **Pupillary Light Reflex (PLR) Protection**: Eliminates pupil miosis caused by standard white/blue screens in non-mydriatic screening booths.
- **Ruby Mode**: 630–660nm deep red monochromatic theme preventing rhodopsin photobleaching.
- **Amber Mode**: 590nm warm amber theme reducing blue-light exposure while maximizing operator reading contrast.
- **Single-Key Toggle**: Press `D` or `F9` anywhere to cycle modes.

### 2. Hands-Free USB Foot-Pedal & Acoustic QC Chimes
- **Zero-Touch Capture**: Step on standard clinical USB foot pedal (`Space`/`Numpad 0`) to trigger capture and advance workflows without releasing the camera joystick.
- **Eyes-Free Tone Feedback**: Double ascending chime confirms focus and illumination pass; low warning alert prompts operator to adjust patient posture eyes-free.
- **Fast Eye Flip**: Press `Tab` or `T` to toggle Right Eye (`OD`) ↔ Left Eye (`OS`).

### 3. Doctor High-Velocity Batch Triage Deck
- **1-Key Rapid Review Sprint**:
  - `1`: Sign off Normal (Routine 1-year annual recall).
  - `2`: Confirm Mild NPDR (HbA1c guidance + 6-month recall).
  - `3`: URGENT VR REFERRAL (< 72h referral).
  - `Space` / `→`: Advance to next case in batch.
  - `Z`: Instant Fullscreen Pan/Zoom fundus inspector.
- **Throughput**: Accelerates grading of 50–150 field camp cases from 25s per case down to ~3s for normal eyes.

### 4. Camp Thermal Receipt Slip (ESC/POS 58mm / 80mm)
- **Low-Cost Portable Hardware Support**: Generates standard ESC/POS binary streams for battery-powered Bluetooth/USB receipt printers ($25–$40 units).
- **Physical Handout**: Prints patient token, masked demographics, OD/OS findings, review timeframe, and ABHA QR verification code directly at camp site.
- **Authentic Modal Preview**: Monospace receipt preview with realistic serrated edges and clipboard/print actions.

### 5. Auto Sequential OD ➔ OS Pipeline
- Dual-eye capture and analysis buffer tied under a single patient registration token.
- Dual-Eye comparative result card comparing OD vs OS side-by-side.

---

## 🧪 Verification & Stability
- **Test Suite**: 50/50 tests passing (100% green across workplace ergonomics, auth, navigation, and clinical models).
- **Static Analysis**: `dart analyze lib/` exits with code 0 (0 errors, 0 warnings).
