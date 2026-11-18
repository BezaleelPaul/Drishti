# Tasks — Specialist & Admin Identity (Google Sign-In)

**Feature:** `specialist-auth`
**Rule:** server first (behind a flag), client second. No task may gate the
field screening path. Every task ends with its tests green.

## Phase 1 — Server foundation

- [ ] T1. `Principal` model + dual credential resolution in `server/api/auth.py`
      (API key unchanged, Bearer JWT added). Tests: existing key tests pass;
      missing/invalid Bearer → 401.
- [ ] T2. `server/api/google_auth.py`: Google ID token verification with
      audience/issuer/expiry checks and JWKS caching. Tests: valid, bad
      signature, wrong audience, expired, wrong issuer.
- [ ] T3. `POST /auth/google` issuing app JWT (HS256, ≤60 min) with role mapping
      rules R3.1–R3.5. Tests: role matrix incl. admin allowlist case-insensitivity.
- [ ] T4. `DRISHTI_HUMAN_AUTH` flag (default off) and startup validation of
      `DRISHTI_JWT_SECRET` / client IDs. Tests: off → 404/disabled; prod without
      secret → refuses to start.

## Phase 2 — Specialist workflow (server)

- [ ] T5. `specialist_applications` table + partial unique index; migration on
      startup (idempotent). Tests: insert, duplicate-pending rejected.
- [ ] T6. `POST /specialists/apply` and `GET /specialists/me` with validation
      (required fields, no PHI). Tests: happy path, duplicate, pending state.
- [ ] T7. `GET /admin/specialists` and `POST /admin/specialists/{id}/decide`
      (admin only, note + actor + time recorded). Tests: 403 for non-admin,
      approve flips token role on next issue, reject blocks resubmission window.
- [ ] T8. Audit events `auth.issue`, `specialist.apply`, `specialist.decide`.
      Tests: events written with actor/role/outcome and no token strings.

## Phase 3 — Flutter client

- [ ] T9. `services/auth_service.dart`: Google sign-in, token exchange, secure
      storage, `AuthState` stream, local expiry checks. Tests: state transitions
      with a mocked transport.
- [ ] T10. `Authorization: Bearer` support in `api_service.dart` alongside the
      API-key path; existing 401/403 honest-notice behaviour preserved.
- [ ] T11. `SignInScreen` + entry points from the dashboard/drawer; honest
      offline/error states; "continue without account" always available.
      Tests: widget tests for states; field flow unaffected with no session.
- [ ] T12. Specialist application + status screen. Tests: validation, pending
      copy, approved/rejected rendering.
- [ ] T13. Admin approvals screen (pending list, approve/reject with note).
      Tests: role-gated rendering; actions call the API and refresh.

## Phase 4 — Gating, hardening, rollout

- [ ] T14. Drawer/dashboard role gating (hide, never fake); Linux explains the
      platform limitation. Tests: nav per role.
- [ ] T15. Rate limits on `/auth/google` and `/specialists/apply`; security
      checklist from design §4 verified.
- [ ] T16. Enable flag in staging; manual Android end-to-end run; document
      screenshots and results in `docs/`.
- [ ] T17. Update `ROADMAP.md` (Phase 7), `DEVELOPER_README.md` (config env vars),
      and the admin portalk docs; add ADR for "field app stays keyless".

## Definition of done

- Field screening works with no account on every platform.
- A specialist can apply, be approved, and review cases with Google sign-in.
- Admin allowlist yields admin access with no application step.
- All new server tests + full Flutter suite green in CI (`test.yml`).
- No PHI or tokens in logs; audit trail covers issuance and decisions.
