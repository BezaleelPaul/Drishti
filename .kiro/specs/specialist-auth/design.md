# Design — Specialist & Admin Identity (Google Sign-In)

**Feature:** `specialist-auth`
**Depends on:** `requirements.md` (approved)
**Constraint:** no change to field screening, offline queue, or patient-data
paths. API-key auth remains the machine path.

## 1. Architecture

```
┌─────────────────────────── Flutter app ───────────────────────────┐
│  Field mode (default, no account)                                 │
│    screening · history · offline queue · sync key                 │
│                                                                   │
│  Privileged mode (opt-in)                                         │
│    SignInScreen ── google_sign_in ──▶ ID token                    │
│         │                                                         │
│         ▼                                                         │
│    POST /auth/google ──▶ app JWT ──▶ flutter_secure_storage       │
│         │                              │                          │
│         ▼                              ▼                          │
│    role-gated drawer: Review Queue (doctor) / Admin Portal (admin)│
└───────────────────────────────────────────────────────────────────┘
                            │ HTTPS
┌───────────────────────────▼───────────────────────────────────────┐
│  FastAPI server                                                   │
│    /auth/google       → verify Google token → map role → JWT      │
│    /specialists/*     → application submit/read (self)            │
│    /admin/specialists → list/approve/reject (admin only)          │
│    existing routes    → Depends(require_role) unchanged           │
│                                                                   │
│  principal: email + role (+ specialist_status)                    │
│  sources:  X-API-Key (machine) | Bearer <app JWT> (human)         │
└───────────────────────────────────────────────────────────────────┘
                            │
                     SQLite (existing DB)
                     + specialist_applications
                     + audit_log (existing, extended)
```

## 2. Server changes

### 2.1 Principal resolution
`server/api/auth.py` keeps `ApiPrincipal(key_fingerprint, role)`. Extend it to:

```python
@dataclass(frozen=True)
class Principal:
    subject: str          # "key:<fingerprint>" or "user:<email>"
    role: str             # operator | doctor | admin
    email: str | None = None
```

`require_role(role)` accepts **either**:
- `X-API-Key` → existing key→role map (unchanged), or
- `Authorization: Bearer <app JWT>` → verified claims.

Resolution order: explicit API key first (machines never send both).

### 2.2 Google token verification
```python
# server/api/google_auth.py
def verify_google_id_token(id_token: str, client_ids: list[str]) -> GoogleIdentity:
    """Verify signature/iss/aud/exp against Google's JWKS; return email + sub.

    Raises InvalidTokenError. Caches JWKS per process (refresh on unknown kid).
    """
```
Implementation: `google-auth`'s `id_token.verify_oauth2_token` (adds a small,
well-maintained dependency) rather than hand-rolled JWKS handling.

### 2.3 App JWT
- HS256 with `DRISHTI_JWT_SECRET` (≥ 32 bytes; server refuses to start in prod
  without it).
- Claims: `sub`, `email`, `role`, `specialist_status`, `iat`, `exp` (≤ 60 min).
- Refresh = re-verify a fresh Google ID token (no long-lived refresh tokens).

### 2.4 Role mapping
```
email in DRISHTI_ADMIN_EMAILS (constant-time, case-insensitive)
    → admin
approved specialist row for email
    → doctor
pending specialist row
    → operator + specialist_status=pending
otherwise
    → operator
```

### 2.5 Specialist applications table
```sql
CREATE TABLE IF NOT EXISTS specialist_applications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL,
  full_name TEXT NOT NULL,
  council_reg_no TEXT NOT NULL,
  specialty TEXT NOT NULL,
  license_ref TEXT,                 -- path/reference only, never PHI
  status TEXT NOT NULL CHECK (status IN ('pending','approved','rejected')),
  submitted_at TEXT NOT NULL,
  decided_at TEXT,
  decided_by TEXT,
  decision_note TEXT,
  UNIQUE (email, status) WHERE status = 'pending'   -- one open application
);
```
(Implemented as a partial unique index.)

### 2.6 Endpoints

| Method | Path | Role | Purpose |
|---|---|---|---|
| POST | `/auth/google` | public | Verify Google token, return app JWT + role |
| GET | `/specialists/me` | any signed-in | Application status |
| POST | `/specialists/apply` | any signed-in, no approved record | Submit application |
| GET | `/admin/specialists` | admin | List by status |
| POST | `/admin/specialists/{id}/decide` | admin | approve/reject + note |

All responses use existing pydantic schemas; errors use the existing error
envelope so the Flutter client's honest-notice path keeps working.

### 2.7 Audit
Reuse the existing audit log: add event types `auth.issue`, `specialist.apply`,
`specialist.decide`. Fields: actor, role, outcome, timestamp. No tokens, no PHI.

## 3. Flutter changes

| File | Change |
|---|---|
| `services/auth_service.dart` (new) | Google sign-in, token exchange, secure storage, current role stream |
| `services/api_service.dart` | Send `Authorization: Bearer` when a session exists; keep API key path |
| `screens/auth/sign_in_screen.dart` (new) | Google button, honest offline/error states, "continue without account" |
| `screens/auth/specialist_application_screen.dart` (new) | Application form + status view |
| `screens/admin/specialist_approvals_screen.dart` (new) | Pending list, approve/reject |
| `widgets/nav/neon_nav_rail.dart` | Show privileged entries only when role permits |
| `main.dart` | Restore cached session; never block startup on it |

Platform note: `google_sign_in` supports Android/iOS/macOS/Web; **not Linux
desktop**. On Linux, sign-in UI explains the limitation and keeps field mode
fully usable (privileged review happens on mobile/web).

### 3.1 State model
```
AuthState: signedOut | verifying | signedIn(role, email, specialistStatus)
```
Role gating is presentation-only; the server remains the authority (403 on
privileged calls). The drawer never hides a control to *fake* security — it
hides it to reduce noise; the API is still guarded.

### 3.2 Offline behaviour
- Tokens cached; expiry checked locally before privileged calls.
- Expired + offline → privileged screens show "sign in when online"; screening
  continues.
- Never upgrade a cached role after a server denial (R6.4).

## 4. Security review checklist

- [ ] Google token audience restricted to configured client IDs
- [ ] JWT secret required in prod; dev key refused on LAN
- [ ] Token TTL ≤ 60 min; no refresh token stored
- [ ] Secure storage only; no tokens in logs, URLs, or analytics
- [ ] Rate-limit `/auth/google` and `/specialists/apply`
- [ ] Partial unique index prevents duplicate open applications
- [ ] Admin allowlist compared in constant time
- [ ] Existing API-key tests unchanged and green

## 5. Test plan

**Server (pytest)**
- token verification: valid / bad signature / wrong audience / expired / wrong issuer
- role mapping matrix: admin, approved doctor, pending, unknown
- application lifecycle: submit → duplicate rejected → approve → role upgrade
- authorization: operator/pending get 403 on review + admin routes
- API-key path still passes existing integration tests untouched

**Flutter**
- sign-in screen renders offline/error states honestly
- drawer hides privileged entries per role
- application form validation (required fields, council number format)
- cached-session expiry leaves field app usable
- widget test: field screening works with no session at all

**Manual**
- Linux: field mode unaffected; sign-in explains platform limitation
- Android: full flow against a staging server

## 6. Rollout

1. Server: token verification + JWT + role mapping behind
   `DRISHTI_HUMAN_AUTH=enabled` (default off) — zero behaviour change when off.
2. Flutter: sign-in entry hidden while the flag is off.
3. Enable in staging, run the test matrix, then enable in release.
4. Keep API-key provisioning documented for ASHA devices.

## 7. Out of scope (explicit)

- Patient accounts / self-service patients (field workflow stays operator-led).
- Multi-tenant organisations, SSO beyond Google, refresh-token rotation.
- Password auth, SMS OTP, biometric device unlock.
- Changes to audit retention or PHI handling.
