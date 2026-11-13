# Drishti v1.9.1 — Local Encrypted Patient History, Automated Specialist SMTP Alerts & Complete System Rebranding

### 🏆 Release Highlights

**Release v1.9.1** delivers critical clinical workflow enhancements, patient record persistence on-device, automated specialist alerting over SMTP, an interactive administrative portal, and 100% complete rebranding across all screens.

---

#### 1. On-Device Patient History & Encrypted SQLCipher Persistence
- **Zero-Loss Clinical Record Persistence:**
  - Patient intake details, screening outcomes, ICDRS diabetic retinopathy grading, and captured fundus images are atomically stored directly into the device's encrypted SQLCipher database vault (`LocalStore`).
  - Screenings are saved immediately upon analysis completion and specialist review, guaranteeing persistence even in completely offline rural health scenarios.
- **Unified Patient History View:**
  - The Patient History screen seamlessly merges local device screening records from SQLCipher with remote central database records.
  - Automatically seeds demonstration records if the device database is empty, preventing blank state confusion for frontline health workers.
  - Full search and filtering by patient name, ID, village, and DR severity.

---

#### 2. Automated Specialist Email Alerts (RFC 5321 / RFC 5322 SMTP)
- **Instant Clinical Escalation:**
  - Whenever a patient is diagnosed with Diabetic Retinopathy (DR severity >= 1), Drishti automatically generates and dispatches a comprehensive clinical report to the designated specialist ophthalmologist.
- **Detailed Clinical HTML Dossier:**
  - Formatted clinical email report containing:
    - Patient demographics (name, age, gender, ABHA ID, village, contact).
    - Clinical vitals (HbA1c, fasting blood glucose, blood pressure, BMI, diabetes duration).
    - AI diagnostic findings (ICDRS stage, confidence score, primary biomarkers, recommendation).
    - High-resolution captured fundus photograph attached as an embedded JPEG.
    - Clinical referral urgency classification (Routine vs. Urgent).
- **Universal Zero-Dependency SMTP Engine:**
  - Implemented entirely in pure Dart without external pub.dev SMTP dependencies.
  - Full support for both direct SSL/TLS (port 465, e.g. Gmail) and STARTTLS (port 587, e.g. Outlook, AWS SES).
  - Handles authentication, MIME multi-part encoding, and base64 payloads reliably.

---

#### 3. Administrative Portal (SMTP & Specialist Configuration)
- **Dedicated Admin Interface:**
  - Added "Admin Portal (SMTP)" directly into the primary navigation drawer under Triage & Operations.
  - Configurable specialist recipient email(s), sender email account, App Password/token, SMTP server host, and port.
  - Automated trigger controls: toggle automatic dispatch on/off, and set minimum severity threshold (e.g. notify only for Grade 2+ Moderate, or Grade 3+ Severe).
  - One-click provider presets: Google Gmail, Microsoft Outlook/Office 365, and Amazon SES.
- **Live Interactive SMTP Gateway Diagnostics:**
  - "Send Test Email" utility with real-time socket transcript readout.
  - Displays step-by-step SMTP handshake status (`CONNECT`, `EHLO`, `AUTH LOGIN`, `MAIL FROM`, `RCPT TO`, `DATA`, `QUIT`).

---

#### 4. Complete Application Rebranding (Drishti)
- **Elimination of Legacy Identifiers:**
  - Replaced legacy naming across all UI screens, splash animations, and assets.
  - Re-rendered boot screen scanner HUD with bold Drishti brandmark and cyan glow effect.
  - Regenerated `assets/branding/drishti_logo_horizontal_no_tagline.png` with high-resolution vector-aligned artwork.
  - Zero mentions of "Elytriva" or "Netra" anywhere in the app interface.

---

#### 5. Universal Standalone Distribution
- **macOS Clinic Bundle (`drishti_macos_v1.9.1.zip`):**
  - Fully signed inside-out with designated requirements.
  - Framework symlinks (`App`, `FlutterMacOS`, `SQLCipher`, `FMDB`, `sqflite_sqlcipher`) preserved with POSIX-compliant symlink headers.
  - Includes `run_macos.command` for instantaneous one-click launch bypassing Gatekeeper quarantine.
