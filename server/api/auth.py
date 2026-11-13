"""
API-key authentication with role-based access control for Drishti-AI.

Roles:
  - operator : field screening (patients, retinal, sync, risk reads/writes)
  - doctor   : everything operator can do + review queue + verdicts
  - admin    : everything (user management placeholder, full access)

Key configuration via environment:
  DRISHTI_API_KEYS="key1:operator,key2:doctor,key3:admin"
  ENV=prod  -> server refuses to start without DRISHTI_API_KEYS set.
  otherwise -> built-in DEV keys are active (loud warning, never for prod).

Clients send:  X-API-Key: <key>
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import APIKeyHeader

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


@dataclass(frozen=True)
class ApiPrincipal:
    """Authenticated caller identity (key fingerprint + role)."""

    key_fingerprint: str
    role: str


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


def authenticate(request: Request, api_key: str | None = Depends(_api_key_header)) -> ApiPrincipal:
    """Validate the API key using constant-time comparison. 401 on failure."""
    role: str | None = None
    if api_key and len(api_key) <= _MAX_PRESENTED_KEY_LEN:
        for known_key, known_role in _API_KEYS.items():
            if hmac.compare_digest(api_key, known_key):
                role = known_role
                break
    if role is None:
        _audit_auth_failure(request)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Missing or invalid API key. Send a valid key in the '{API_KEY_HEADER}' header.",
        )
    return ApiPrincipal(key_fingerprint=_fingerprint(api_key or ""), role=role)


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
                f"{principal.role}:{principal.key_fingerprint}",
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
                    f"{principal.role}:{principal.key_fingerprint}",
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
