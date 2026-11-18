# Requirements — Specialist & Admin Identity (Google Sign-In)

**Feature:** `specialist-auth`
**Status:** Draft (awaiting approval)
**Context:** Field screening stays keyless by product decision (ASHA / PHC
operators, shared devices, offline villages). Identity is required only where
clinical accountability exists: specialists confirming AI grades, and admins
approving them. Today those roles are `X-API-Key` strings distributed via
`DRISHTI_API_KEYS` — adequate for machines, wrong for people.

## Glossary

| Term | Meaning |
|---|---|
| Operator | Field user running screenings. No account. Device provisioned with a sync key. |
| Specialist | Clinician who reviews AI grades. Must be verified before acting. |
| Admin | Operates the platform: approves specialists, manages configuration. |
| Google ID token | Signed JWT issued by Google after interactive sign-in. |
| App JWT | Short-lived token issued by Drishti's server carrying the role. |

## Requirements

### R1 — Field app remains login-free
1. WHEN the app starts without any account, THE system SHALL present the full
   screening workflow exactly as today.
2. THE system SHALL NOT gate screenings, local history, or offline sync behind
   sign-in.
3. WHEN a user chooses "Specialist" or "Admin" entry, THE system SHALL require
   sign-in for those surfaces only.

### R2 — Google sign-in for privileged roles
1. WHEN a user signs in with Google, THE client SHALL send the Google ID token
   to `POST /auth/google` over TLS.
2. THE server SHALL verify the token's signature, issuer (`accounts.google.com`),
   audience (configured client IDs), and expiry before trusting any claim.
3. IF verification fails, THE server SHALL return 401 and SHALL NOT create a
   session.
4. THE server SHALL request only `openid email profile` scopes; no other Google
   data SHALL be requested or stored.

### R3 — Role assignment rules
1. IF the verified email is in `DRISHTI_ADMIN_EMAILS`, THE server SHALL issue a
   session with role `admin`.
2. ELSE IF the email belongs to an **approved** specialist record, THE server
   SHALL issue role `doctor`.
3. ELSE IF the email belongs to a `pending` specialist record, THE server SHALL
   issue a limited session that can read its application status and nothing else.
4. ELSE THE server SHALL issue role `operator` (no privileged access) and SHALL
   surface the specialist-application path in the UI.
5. Admin allowlist checks SHALL be case-insensitive and constant-time.

### R4 — App JWT and session lifetime
1. THE server SHALL issue an app JWT containing `sub`, `email`, `role`,
   `specialist_status`, `iat`, `exp`, signed with the server key.
2. THE token SHALL expire in ≤ 60 minutes; clients SHALL refresh by re-verifying
   a fresh Google ID token.
3. THE client SHALL store tokens only in `flutter_secure_storage`.
4. THE token SHALL NOT contain patient identifiers or clinical data.

### R5 — Specialist application workflow
1. A signed-in user without an approved record SHALL be able to submit an
   application: full name, medical council registration number, specialty,
   optional license document reference.
2. THE server SHALL persist applications with status `pending`.
3. AN admin SHALL be able to list pending applications and approve or reject
   each with an optional note; decisions SHALL be recorded with actor and time.
4. ON approval, the applicant's next token issuance SHALL carry role `doctor`.
5. ON rejection, the applicant SHALL see the decision and note; resubmission
   SHALL be allowed after a documented cooling period (default: 7 days).
6. Duplicate applications for the same email SHALL NOT create parallel records.

### R6 — Honest failure and offline behaviour
1. WHEN the network is unavailable at sign-in, THE client SHALL report that
   clearly and SHALL leave the field workflow fully usable.
2. WHEN a cached session expires while offline, THE client SHALL keep local
   screening available and SHALL NOT display privileged server data.
3. WHEN the server rejects a privileged request (401/403), THE client SHALL
   present the existing honest auth notice pattern, not a silent failure.
4. THE system SHALL NOT fabricate a role from a cached value after the server
   has explicitly denied it.

### R7 — Auditability
1. THE server SHALL log every token issuance, application decision, and
   privileged API access with actor email, role, timestamp and outcome.
2. Audit records SHALL NOT include Google tokens or PHI.

### R8 — Compatibility
1. Existing `X-API-Key` authentication SHALL continue to work unchanged
   (machines, CI, field provisioning).
2. App JWTs and API keys SHALL map onto the same principal/role model
   (`operator` < `doctor` < `admin`).
3. Existing integration tests for API-key auth SHALL pass unmodified.

## Acceptance criteria

- A user with no account can complete a screening end-to-end without any prompt.
- An unapproved specialist can sign in, apply, and sees `pending`; privileged
  endpoints return 403.
- After admin approval, the same account receives role `doctor` and can access
  the review queue and record verdicts.
- An admin email from the allowlist receives role `admin` without an application.
- A revoked/expired token cannot access review endpoints; the client shows the
  honest auth notice.
- No patient data appears in any token, URL, or audit line.
