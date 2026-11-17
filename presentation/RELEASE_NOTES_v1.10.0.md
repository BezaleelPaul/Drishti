# Drishti v1.10.0 — Offline Specialist Routing & Clinical Hardening

### Release Highlights

**Drishti v1.10.0** adds an offline-first specialist referral router that selects the nearest suitable ophthalmologist, addresses the clinical dossier to that specialist, and recommends **in-person care or teleconsultation** based on urgency, travel time and availability. It also ships the security and reliability hardening identified in the v1.9.2 audit.

---

#### 1. Nearest-Specialist Routing (Dijkstra Facility Graph)
- **Offline routing engine:** destinations are modelled as a facility graph and ranked with **Dijkstra's shortest-path algorithm** over travel time. When no imported road graph exists, the engine uses Haversine facility edges with a rural road factor and 35 km/h estimate — clearly labelled as an estimate, never as turn-by-turn navigation.
- **Clinical scoring, not just distance:** eligibility checks the destination's maximum manageable ICDR grade and retinal capability; ranking also considers waiting time, teleconsult availability and urgency.
- **In-person vs teleconsult:** urgent cases that are far away are preferentially routed to teleconsultation when available, with the in-person facility retained as the escalation path.
- **Addressed dossier:** the selected specialist, facility, distance, travel time, recommended mode and routing rationale are stored with the screening and printed in the clinical PDF and email.
- **Primary + alternates:** the plan includes two escalation alternates; the operator can override the destination from a ranked specialist picker.
- **Actions:** one-tap teleconsult link and native maps directions from the referral screen.
- **Admin directory:** new **Admin Portal → Specialist Routing Directory** screen to manage facilities, specialists, capabilities, waiting times, teleconsult links and the screening-centre origin. A clearly-labelled synthetic demo directory is available for training.

#### 2. Security Hardening
- **Android signing key rotated.** The committed keystore and public password are gone. CI now restores the new key from `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` secrets. **v1.9.x APKs must be uninstalled once before installing v1.10.0.**
- **Encrypted secondary persistence:** the SharedPreferences cache and filesystem backup are now AES-256-GCM envelopes (`DENC1:`). Patient names, phone numbers and clinical data are no longer readable in preferences or JSON files. Legacy plaintext data is migrated on first read.
- **No hardcoded vault key:** the device key comes from the OS keychain, then a permission-restricted key file, then a process-memory key. The previous static fallback is removed.
- **SMTP credentials in the OS keychain:** app passwords are no longer written to SharedPreferences. If no keychain is available the secret stays in memory for the session.
- **No automatic PHI email:** the analysis screen no longer emails the specialist. Dispatch happens from the referral screen only after explicit patient consent and with the routed recipient previewed.
- **De-identified PDF filenames:** reports and attachments use the local screening ID and eye side, never the patient name.
- **Demo data is opt-in:** clinical builds never fabricate patients. Demo records/directories require an explicit action or `--dart-define=DRISHTI_DEMO_MODE=true`.
- **Minimal Android permissions:** the report opener's broad media permissions are removed; only `INTERNET` and `CAMERA` remain.

#### 3. Reliability & Release Engineering
- **Single vault connection:** the local database stays open for the app lifetime instead of being closed and reopened on every read/write.
- **Schema v2:** referral plans and email-dispatch state are persisted in the local vault with an idempotent migration.
- **Queue health panel:** Admin Portal now shows durable-queue status, queued screenings/patients and pending sync receipts.
- **Smaller Android downloads:** the APK is built per ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) instead of one 167 MB universal package.
- **CI quality gate expanded:** routing, encryption, SMTP, persistence and report tests run before builds; Flutter is pinned to 3.50.0.
- **Release checksums:** every release includes `SHA256SUMS.txt`.
- **Desktop camera guidance:** the camera screen now explains the ffmpeg requirement and platform install commands.

---

### Downloads (v1.10.0)

| Platform | Asset | How to run |
| :--- | :--- | :--- |
| **Android arm64** | `Drishti_mobile_v1.10.0_arm64-v8a.apk` | Modern phones/tablets |
| **Android armv7** | `Drishti_mobile_v1.10.0_armeabi-v7a.apk` | Older 32-bit devices |
| **Android x86_64** | `Drishti_mobile_v1.10.0_x86_64.apk` | Emulators / x86 tablets |
| **Linux x86_64** | `Drishti_linux_v1.10.0.tar.gz` | Extract and run `./run_drishti.sh` |
| **Windows x86_64** | `Drishti_windows_v1.10.0.zip` | Extract and run `run_drishti.bat` |
| **macOS** | `Drishti_macos_v1.10.0.zip` | Extract and double-click `run_macos.command` |
| **iOS** | `Drishti_ios_unsigned_v1.10.0.zip` | Unsigned bundle for sideloading/TestFlight |

Every download is listed in `SHA256SUMS.txt`.

### Upgrade Notes
- **Android:** the signing key changed. Uninstall the old v1.9.x sideloaded app once, then install the matching ABI APK.
- Existing patient vaults are migrated in place; encrypted cache/backup files are created automatically.
- Routing requires a configured screening-centre origin and at least one active specialist. Until then the referral screen shows a setup prompt.

### Known Limits
- The default facility graph is a Haversine estimate; an OSM/OSRM road graph can replace it without changing the engine. Always confirm the destination clinically.
- Windows/Linux use a native SQLite vault inside the OS user-profile container. Enable FileVault/BitLocker/LUKS for full-disk encryption; SQLCipher on desktop is not yet bundled.
- Full five-language localization of every legacy screen, macOS notarization and Windows Authenticode signing remain follow-up work.
