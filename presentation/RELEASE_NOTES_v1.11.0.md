# Drishti v1.11.0 — Local Hospital Auth & Role-Based Data Abstraction

### Release Highlights

**Drishti v1.11.0** introduces a fully offline **Local Hospital Authentication System** and **Role-Based Clinical Data Abstraction** (least-privilege access control). Designed specifically for hospital eye wings and remote screening camps, v1.11.0 eliminates external Google OAuth dependencies, replaces them with on-device facility sessions, and separates operational screening workflows from sensitive clinical diagnostic triage.

---

#### 1. Local Hospital Authentication (100% Offline)
- **Zero Cloud Sign-in Dependency:** Completely removed Google OAuth/Firebase auth blockers. Hospitals and rural camps can operate with zero external internet connectivity.
- **Dual-Role Separation:**
  - **Camera Operator / Imaging Technician:** Focused on rapid patient registration, live fundus camera capture, image focus/quality verification, and local offline queue management.
  - **Hospital Clinician / Doctor / Ophthalmologist:** Authorized for full longitudinal medical record triage, diagnostic ICDRS grades (0–4), microaneurysm detection, Grad-CAM attention heatmaps, specialist referrals, and PDF report signing.
- **Clinician PIN Security Gate:** Sensitive clinical doctor records and triage actions are protected with a hospital PIN code (default `1234`, configurable).
- **One-Tap Quick Hospital Access:** Rapid-intake buttons for District General Hospital eye wings and camp deployment.

#### 2. Role-Based Data Hiding & PII Abstraction
- **Least-Privilege Principle (HIPAA & DISHA Compliant):**
  - **Diagnostic Abstraction:** Complex or sight-threatening retinopathy classifications (e.g. *Severe NPDR*, *Proliferative DR*, *High DME Risk*) are abstracted from the camera operator in the screening booth to prevent patient alarm. Instead, the operator sees: *"Capture Verified · Stored in Doctor Queue"*.
  - **PII Masking:** Patient names are shortened to initials and surname (e.g., `S. Patel` or `P***`), contact numbers are masked (`+91 98••• •••210`), and residential sectors are masked (`Sector Protected`) in open screening areas.
  - **Optical Quality HUD:** The diagnostic severity spectrum is replaced with an optical QC card (*Focus, illumination, and centering verification*) for technicians.
  - **On-Demand Clinician PIN Unlock:** Doctors can unlock full unmasked records and specialist actions on the spot without logging out of the workstation.
  - **Locked Administrative Actions:** PDF report generation, specialist email routing, record editing, and patient deletion are locked behind clinician PIN authorization.

#### 3. Modernized Clinical HUD & Bento Grid Dashboard
- **Role-Adaptive Dashboard:** Stat cards, quick-actions, and navigation items automatically adapt to the logged-in role. Camera operators see intake counters, offline sync spools, and focus pass rates; clinicians see urgent referral tallies and awaiting sign-offs.
- **Active Session Badges:** AppBar displays active facility pill and staff badges (`DR · Sharma` or `TECH · Ramesh`) with instant role-switching modal bottom sheets.
- **Pathology Curve Abstraction:** Aggregate disease severity curves and referral distributions are hidden when operated by technicians.

#### 4. Desktop Workstation Impeller Acceleration
- **Updated Linux Desktop Bundle (`linux_app/bundle`):** Recompiled with Flutter's next-generation Impeller OpenGL ES rendering backend for smooth 60fps retinal inspection.

---

### Downloads (v1.11.0)

| Platform | Asset | How to run |
| :--- | :--- | :--- |
| **Android arm64** | `Drishti_mobile_v1.11.0_arm64-v8a.apk` | Modern phones/tablets |
| **Android armv7** | `Drishti_mobile_v1.11.0_armeabi-v7a.apk` | Older 32-bit devices |
| **Android x86_64** | `Drishti_mobile_v1.11.0_x86_64.apk` | Emulators / x86 tablets |
| **Linux x86_64** | `Drishti_linux_v1.11.0.tar.gz` | Extract and run `./run_drishti.sh` |
| **Windows x86_64** | `Drishti_windows_v1.11.0.zip` | Extract and run `run_drishti.bat` |
| **macOS** | `Drishti_macos_v1.11.0.zip` | Extract and double-click `run_macos.command` |
| **iOS** | `Drishti_ios_unsigned_v1.11.0.zip` | Unsigned bundle for sideloading/TestFlight |
