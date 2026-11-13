# Drishti — Privacy & Access-Control Matrix

> Health screening data (fundus photos, demographics, ABHA/phone) is sensitive
> personal data under India's DPDP Act (and HIPAA/GDPR equivalents where
> applicable). This document is the contract for who can see what, where data
> lives, and what guarantees the system gives. Code references are the
> enforcement — not aspirations.

## 1. Roles

| Role | Who | Key | Sees |
|---|---|---|---|
| **Operator** (ASHA/PHC worker) | Field screening on the mobile app | `X-API-Key` with `operator` role | Own centre's patients (register/search/list), capture + quality + AI results for those patients, own offline queue |
| **Doctor** (tele-ophthalmologist) | Review queue + verdicts | `X-API-Key` with `doctor` role | Everything an operator sees, **plus** the review queue (`GET /review/pending`) and verdict submission (`POST /review/{id}`) |
| **Admin** | Deployments, audits | `X-API-Key` with `admin` role | Everything, plus the `audit_log` compliance trail. No admin-only mutating endpoints exist yet (`require_admin` is reserved) |
| **Patient** | The screened individual | — (no login) | Sees only their own result via the operator's device (SMS slip / referral printout). Patients never get API keys |

Role hierarchy is enforced server-side (`api/auth.py`): `admin > doctor > operator`.
The client can claim nothing — every request re-validates the key.

## 2. Endpoint guards (all in `api/routes/`)

| Endpoint | Guard | Notes |
|---|---|---|
| `POST /patients`, `GET /patients`, `GET /patients/{id}` | any authenticated key | Full PHI incl. phone + ABHA. Intended for single-PHC use; every read is audit-logged (`patient_list`, `patient_read`) |
| `POST /retinal/quality`, `POST /retinal/analyze`, `GET /retinal/screenings/{id}` | any authenticated key | Images + grades |
| `GET /results/{id}/{file}` | any authenticated key | Path-traversal hardened; reads **and misses** audited (`result_read`, `result_read_404`) so ID enumeration leaves a trace |
| `POST /diabetes-risk`, `POST /sync`, `GET /status` | any authenticated key | v1 sync: full-PHI field-camp replay, requires patients pre-registered |
| **`POST /sync/v2`** | any authenticated key | **De-identified contract** (C-4): pseudonym-only payload; fail-closed PHI linter (whitelist + mobile/ABHA/salutation tripwires); one violation rejects the whole batch with 422; **no PHI columns exist in `deid_screenings`**; no server-side inference; every accept/reject/replay audited with pseudonyms only. Rejected payloads are never persisted or quarantined |
| **`GET /sync/v2/pending`, `GET /sync/v2/image/{id}`** | **doctor or admin only** | Pseudonymized referral queue + stored (downscaled, EXIF-stripped) image. Operators get 403. 422 validation errors are value-redacted globally (`main.py` handler) — field names, never values |
| `GET /review/pending`, `POST /review/{id}` | **doctor or admin only** | An operator key gets 401/403. The app surfaces "doctor key required" instead of a fake empty queue |
| `GET /cameras`, `GET /samples` | public | No PHI: camera specs + fictional demo personas only |
| `GET /` | public | Liveness only, no counts (counts would be an unauthenticated oracle) |

**Client-side honesty rule** (`doctor_review_screen.dart`): a sign-off counts
only when the server accepts it. A rejected verdict reverts the UI and says
so — the app can never display a forged clinical approval.

## 3. Where data lives (local-first)

- **Phone/tablet** (the screening unit — works with airplane mode on):
  - **AI runs on-device** (`lib/services/ml/`): the quality gate + int8
    TFLite classifier + confidence gate run in the app sandbox; the original
    fundus photo never has to leave the device to be graded.
  - **Offline queue is durably persisted** (`lib/services/offline_queue_service.dart`):
    SQLCipher database (`drishti_queue.db`, key generated on-device and held in
    the Android Keystore via flutter_secure_storage), write-through on every
    enqueue, rehydrated at boot — field-camp captures survive process kills.
    If secure storage is unavailable the service degrades to memory-only and
    reports `isPersisted=false` honestly.
  - **On-device screening store** (`lib/services/db/local_store.dart`):
    SQLCipher tables (`patients`, `screenings`, `sync_queue`, `sync_receipts`,
    `consent_records`, `audit_log_local`); receipt-before-delete invariant;
    synced images are deleted from the device after server ACK.
  - **Consent records** (`lib/services/consent_service.dart`): versioned,
    per-patient, **default refusal**, one-tap withdrawal; store local id +
    decision only. Nothing leaves the device without a granted, non-withdrawn
    record for the current consent version.
  - **De-identified referral payloads** (`lib/services/deidentify.dart`):
    pseudonym = HMAC-SHA256(per-device salt, local id) — salt never leaves
    the device; image downscaled to ≤512px and re-encoded (EXIF/GPS/serials
    stripped by construction); age coarse-banded. A client-side PHI linter
    drops any payload that leaves the whitelist BEFORE the network.
  - `SharedPreferences` holds **language preference and consent decisions
    only (no patient identifiers)**. Android backup is disabled
    (`allowBackup=false`, `dataExtractionRules`), so `adb backup` and cloud
    backup cannot exfiltrate the sandbox. Network is HTTPS-only with plaintext
    blocked at the OS layer.
- **Server**: SQLite + `results/api_screenings/` on the deployment host.
  This copy exists to hold the review queue — it is **operational, not
  archival**:
  - `SEED_DEMO_DATA=0` in production (no demo patients seeded),
  - `RETENTION_DAYS` purge job (`api/retention.py`) deletes screenings,
    verdicts, and image dirs older than the window (recommend 90),
  - `/sync/v2` adds a separate `deid_screenings` store with **no PHI
    columns** (pseudonym-keyed; extend `RETENTION_DAYS` purge to it),
  - dev API keys are refused on any non-loopback interface (fail-closed).
- **Never**: no third-party analytics (CI grep-gated), no cloud backup of
  device data, no bundled patient images in the app package (explicit asset
  allowlist in `pubspec.yaml`), no telemetry of any kind.

## 4. Audit trail

`audit_log` table (never purged by retention): authentication failures,
forbidden attempts, patient reads/lists, result reads **and misses**, verdicts,
**plus every `/sync/v2` accept, replay, and rejection (field names only —
never the offending values, including parse-time pydantic rejections, whose
`input` field is globally redacted in `main.py`)**. On-device,
`audit_log_local` mirrors the same discipline (no values, ids + actions).
Review both as the compliance record of who touched whose data.
