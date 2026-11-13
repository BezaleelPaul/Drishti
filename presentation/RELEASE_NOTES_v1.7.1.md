# Drishti (Elytriva) v1.7.1 — Android APK Signing Fix & Production Clinical Release

### 🏆 Release Highlights

**Release v1.7.1** delivers the official production build with **fully resolved Android APK cryptographic signing** alongside our highest-performing clinical model.

#### 1. Android Package Signing & Alignment Fix
- **Issue Resolved:** Fixed `"App not installed as package appears to be invalid"` on Android devices caused by stripped APK signing blocks.
- **Dual Scheme Signing:** Fully signed using RSA 2048-bit keys supporting both **APK Signature Scheme v2 (API 24+)** and **APK Signature Scheme v3 (API 28+)**.
- **4-Byte Zip-Aligned:** Fully aligned using Android SDK `zipalign -p -f 4` for instantaneous memory-mapped zero-copy runtime loading.
- **Target OS:** Tested and validated on Android 7.0 through Android 15+ (`minSdkVersion 24`, `targetSdkVersion 36`).

#### 2. Clinical Production Model (Quad-Loss & 4-View TTA)
- **`96.28%` Referable Sensitivity (Recall)** — only 11 missed referable cases out of 296!
- **`91.03%` Referable Specificity** — exceeds British Diabetic Association $\ge 80\%$ standard.
- **`0.8739` Quadratic Weighted Kappa (QWK)** — Near-Perfect Inter-Rater Agreement.
- **`97.30%` Negative Predictive Value (NPV)** — unmatched frontline triage safety.
- **`80.03%` Multi-Class Accuracy** — balanced across all 5 ICDR severity stages.

---

### 📊 Comprehensive Clinical Performance Progression

| Metric | Baseline | v1.5.0 | v1.6.0 | **v1.7.1 (Production)** | Clinical Significance |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Referable Sensitivity** | 21.0% | 90.54% | 95.27% | **`96.28%`** | Missing only 11 out of 296 sick patients |
| **Referable Specificity** | Unreliable | 94.02% | 89.20% | **`91.03%`** | Exceeds British Diabetic Association $\ge 80\%$ standard |
| **Quadratic Weighted Kappa** | 0.3100 | 0.8533 | 0.8190 | **`0.8739`** | Near-Perfect Agreement with ophthalmologists |
| **Negative Predictive Value** | — | 93.59% | 96.52% | **`97.30%`** | Frontline screening safety confirmed |
| **Positive Predictive Value** | — | 91.16% | 85.71% | **`87.96%`** | High referral fidelity to tertiary care |
| **Top-1 Multi-Class Accuracy** | 71.5% | 79.89% | 73.60% | **`80.03%`** | First model to break 80% multi-class accuracy |
| **False Negatives (Missed Sick)** | High | 28 / 296 | 14 / 296 | **`11 / 296`** | 61% reduction in false negatives vs v1.5.0 |
| **Edge INT8 Model Size** | 15.3 MB | 4.88 MB | 5.08 MB | **`5.08 MB`** | Sub-150ms on mobile without internet/cloud |
| **Hospital Safety Gate** | FAILED | PASSED | PASSED | **`PASSED`** | Gold Standard Production Clinical Grade |

---

### 📦 Release Artifacts Attached

* **Android APK:** `elytriva_mobile_v1.7.1.apk` *(Cryptographically signed with v2/v3 schemes)*
* **Windows Desktop:** `elytriva_windows_v1.7.1.zip`
* **Linux Desktop:** `elytriva_linux_v1.7.1.tar.gz`
* **macOS Desktop:** `elytriva_macos_v1.7.1.zip`
* **iOS Package:** `elytriva_ios_unsigned_v1.7.1.zip`
