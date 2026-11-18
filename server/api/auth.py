"""
Authentication and role-based access control for Drishti-AI.

Two credential paths, one principal model:

  * Machines (field devices, CI): ``X-API-Key: <key>`` — unchanged.
  * Humans (specialists, admins): ``Authorization: Bearer <app JWT>`` issued
    by ``POST /auth/google`` after a verified Google sign-in.

Roles:
  - operator : field screening (patients, retinal, sync, risk reads/writes)
  - doctor   : everything operator can do + review queue + verdicts
  - admin    : everything (user management, specialist approvals)

Key configuration via environment:
  DRISHTI_API_KEYS="key1:operator,key2:doctor,key3:admin"
  ENV=prod  -> server refuses to start without DRISHTI_API_KEYS set.
  otherwise -> built-in DEV keys are active (loud warning, never for prod).
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer

logger = logging.getLogger(__name__)

API_KEY_HEADER = "X-API-Key"
ENV = os.environ.get("ENV", "dev").lower()
IS_PROD = ENV == "prod"

VALID_ROLES = ("operator", "doctor", "admin")
# Role hierarchy: higher index implies all lower privileges.
_ROLE_RANK = {"operator": 1, "doctor": 2, "admin": 3}

# Dev-only fallback keys. Active ONLY when ENV != prod.
_DEV_KEYS: dict[str, str] = {
    "dev-operator-key": "operator",
    "dev-doctor-key": "doctor",
    "dev-admin-key": "admin",
}

_api_key_header = APIKeyHeader(name=API_KEY_HEADER, auto_error=False)
# Bearer is optional: machines never send it, and a bad one must produce a
# 401 here (not a framework 403 with a different error shape).
_bearer_header = HTTPBearer(auto_error=False)

#: Emails that may act as admin without an application (comma-separated).
ADMIN_EMAILS_ENV = "DRISHTI_ADMIN_EMAILS"


@dataclass(frozen=True)
class ApiPrincipal:
    """Authenticated caller identity.

    ``key_fingerprint`` is the API-key fingerprint (empty for JWT callers);
    ``email``/``specialist_status`` are set only for human sessions.
    """

    key_fingerprint: str
    role: str
    email: Optional[str] = None
    specialist_status: Optional[str] = None
    method: str = "api_key"

    @property
    def actor(self) -> str:
        """Audit-safe actor string (never a token or key)."""
        return f"user:{self.email}" if self.email else f"{self.role}:{self.key_fingerprint}"



def _parse_keys(raw: str | None) -> dict[str, str]:
    keys: dict[str, str] = {}
    dropped = 0
    if not raw:
        return keys
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry or ":" not in entry:
            dropped += 1
            continue
        key, _, role = entry.partition(":")
        key, role = key.strip(), role.strip().lower()
        if not key or role not in VALID_ROLES:
            logger.warning("Ignoring malformed DRISHTI_API_KEYS entry (bad role or empty key).")
            dropped += 1
            continue
        keys[key] = role
    if dropped and IS_PROD:
        # A prod server starting with fewer keys than configured is a
        # lockout-or-weaker-auth incident: refuse instead of guessing.
        raise RuntimeError(
            f"DRISHTI_API_KEYS has {dropped} malformed entr(ies). "
            "Expected format 'key:role,key:role' with role in "
            f"{VALID_ROLES}; keys must not contain ',' or ':'."
        )
    return keys


def load_api_keys() -> dict[str, str]:
    """Resolve the active key store. Raises in prod when unconfigured."""
    configured = _parse_keys(os.environ.get("DRISHTI_API_KEYS"))
    if configured:
        if not IS_PROD:
            logger.info("Using %d API key(s) from DRISHTI_API_KEYS.", len(configured))
        return configured
    if IS_PROD:
        raise RuntimeError(
            "ENV=prod but DRISHTI_API_KEYS is not set. Refusing to start "
            "without authentication. Set DRISHTI_API_KEYS='key:role,...'."
        )
    logger.warning(
        "DRISHTI_API_KEYS not set — using built-in DEV keys (operator/doctor/admin). "
        "NEVER use these in production; set ENV=prod with real keys."
    )
    return dict(_DEV_KEYS)


_API_KEYS: dict[str, str] = load_api_keys()


def _fingerprint(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:12]


def uses_dev_keys() -> bool:
    """True when the active key store is the built-in dev fallback."""
    return _API_KEYS == _DEV_KEYS


# Presented keys are hashed and constant-time compared per request: cap
# their length first so a megabyte-long header cannot burn CPU per request.
_MAX_PRESENTED_KEY_LEN = 512

_AUDIT_DDL = (
    "CREATE TABLE IF NOT EXISTS audit_log ("
    "id INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT NOT NULL, "
    "action TEXT NOT NULL, resource TEXT NOT NULL, detail TEXT, "
    "created_at TEXT NOT NULL)"
)


def _audit_row(actor: str, action: str, resource: str, detail: str = "") -> None:
    """Shared auth-audit writer. Creates the table idempotently first: the
    auth path deliberately avoids ensure_db() (no seeding, no per-401 cost),
    so on a fresh data dir the INSERT would otherwise fail with 'no such
    table' and the probe would go unaudited."""
    try:
        from api.database import get_connection

        conn = get_connection()
        try:
            conn.execute(_AUDIT_DDL)
            conn.execute(
                "INSERT INTO audit_log (actor, action, resource, detail, created_at)"
                " VALUES (?, ?, ?, ?, ?)",
                (
                    actor,
                    action,
                    resource,
                    detail[:500],
                    datetime.now(timezone.utc).isoformat(),
                ),
            )
            conn.commit()
        finally:
            conn.close()
    except Exception as e:  # noqa: BLE001 - audit logging must never break requests
        logger.warning("audit_log write failed: %s", e)


def authenticate(
    request: Request,
    api_key: str | None = Depends(_api_key_header),
    bearer: HTTPAuthorizationCredentials | None = Depends(_bearer_header),
) -> ApiPrincipal:
    """Resolve a principal from either credential path. 401 on failure.

    Explicit API key first: machines never send a bearer token, so this
    ordering cannot mask a human session.
    """
    role: str | None = None
    if api_key and len(api_key) <= _MAX_PRESENTED_KEY_LEN:
        for known_key, known_role in _API_KEYS.items():
            if hmac.compare_digest(api_key, known_key):
                role = known_role
                break
    if role is not None:
        return ApiPrincipal(key_fingerprint=_fingerprint(api_key or ""), role=role)

    if bearer is not None and bearer.scheme.lower() == "bearer" and bearer.credentials:
        principal = _principal_from_app_token(bearer.credentials)
        if principal is not None:
            return principal

    _audit_auth_failure(request)
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=(
            f"Missing or invalid credentials. Send a valid key in the "
            f"'{API_KEY_HEADER}' header, or a session token as "
            "'Authorization: Bearer <token>'."
        ),
    )


def _principal_from_app_token(token: str) -> ApiPrincipal | None:
    """Decode an app JWT into a principal; None when untrusted."""
    try:
        from api.app_jwt import InvalidAppTokenError, decode_app_token

        claims = decode_app_token(token)
    except InvalidAppTokenError:
        return None
    except RuntimeError as exc:  # misconfiguration (e.g. prod without secret)
        logger.warning("App-token verification unavailable: %s", exc)
        return None
    if claims.role not in VALID_ROLES:
        return None
    return ApiPrincipal(
        key_fingerprint="",
        role=claims.role,
        email=claims.email,
        specialist_status=claims.specialist_status,
        method="app_jwt",
    )


def admin_emails() -> frozenset[str]:
    """Configured admin allowlist, normalised for comparison."""
    raw = os.environ.get(ADMIN_EMAILS_ENV, "")
    return frozenset(part.strip().lower() for part in raw.split(",") if part.strip())


def resolve_privileged_role(email: str, specialist_status: str | None) -> tuple[str, str | None]:
    """Map a verified email + specialist status to a role.

    Order (spec R3): admin allowlist -> approved specialist (doctor) ->
    operator (pending/absent/rejected). Returns ``(role, specialist_status)``.
    """
    normalised = (email or "").strip().lower()
    # Constant-time membership check: compare against every entry rather
    # than short-circuiting, so the timing does not reveal prefix matches.
    is_admin = False
    for candidate in admin_emails():
        if hmac.compare_digest(normalised, candidate):
            is_admin = True
    if is_admin:
        return "admin", "approved"
    if specialist_status == "approved":
        return "doctor", "approved"
    if specialist_status == "pending":
        return "operator", "pending"
    if specialist_status == "rejected":
        return "operator", "rejected"
    return "operator", None


def _audit_auth_failure(request: Request) -> None:
    _audit_row(
        "anonymous",
        "auth_failure",
        request.url.path,
        f"client={request.client.host if request.client else '?'}",
    )


def _role_allows(principal_role: str, *allowed: str) -> bool:
    """Role-aware authorization using the documented hierarchy: admin >= doctor >= operator.

    For a dependency declared as `require_role("doctor")`, both doctor and admin
    are accepted because admin is a higher-ranked role with all doctor privileges.
    """
    if not allowed:
        return False
    if principal_role not in _ROLE_RANK:
        return False
    min_rank = min(_ROLE_RANK[role] for role in allowed if role in _ROLE_RANK)
    return _ROLE_RANK[principal_role] >= min_rank


def require_role(*allowed: str):
    """Dependency factory enforcing minimum role. 403 carries a generic
    message (no role oracle) and is audited like a 401."""
    allowed = tuple(allowed)
    normalized = tuple(role for role in allowed if role in _ROLE_RANK)
    if not normalized:
        raise ValueError(f"require_role() requires at least one valid role: {VALID_ROLES}")

    async def _guard(
        request: Request,
        principal: ApiPrincipal = Depends(authenticate),
    ) -> ApiPrincipal:
        if not _role_allows(principal.role, *normalized):
            _audit_row(
                principal.actor,
                "auth_forbidden",
                request.url.path,
            )
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Forbidden.",
            )
        return principal

    return _guard


# Any authenticated key (operator and up).
require_auth = require_role("operator", "doctor", "admin")
# Doctor verdicts and review queue (doctors and admins only).
require_doctor = require_role("doctor", "admin")
# Admin-only operations.
require_admin = require_role("admin")


def audit_action(
    principal: ApiPrincipal,
    action: str,
    resource: str,
    detail: str = "",
) -> None:
    """Best-effort audit record for sensitive actions (verdicts, overrides)."""
    try:
        from api.database import get_db

        with get_db() as conn:
            conn.execute(
                "INSERT INTO audit_log (actor, action, resource, detail, created_at)"
                " VALUES (?, ?, ?, ?, ?)",
                (
                    principal.actor,
                    action,
                    resource,
                    detail[:500],
                    datetime.now(timezone.utc).isoformat(),
                ),
            )
            conn.commit()
    except Exception as e:  # noqa: BLE001 - audit logging must never break requests
        logger.warning("audit_log write failed: %s", e)


def active_key_count() -> int:
    return len(_API_KEYS)


def list_roles() -> list[str]:
    return list(VALID_ROLES)
