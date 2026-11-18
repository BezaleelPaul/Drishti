"""Short-lived app session tokens for human (specialist/admin) sign-in.

Design rules from the spec:
  * HS256, signed with ``DRISHTI_JWT_SECRET`` (server key, never shipped).
  * TTL <= 60 minutes; the client refreshes by presenting a fresh Google
    ID token, so no refresh token is stored.
  * Claims carry identity and role only — never patient data.
  * Dev convenience: when the human-auth feature is off and ENV != prod, an
    ephemeral secret keeps local development working with a loud warning.
    In prod, a missing secret with human auth enabled is a startup error.
"""

from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt

logger = logging.getLogger(__name__)

JWT_SECRET_ENV = "DRISHTI_JWT_SECRET"
HUMAN_AUTH_ENV = "DRISHTI_HUMAN_AUTH"
JWT_ISSUER = "drishti"
JWT_AUDIENCE = "drishti-app"
MAX_TTL_MINUTES = 60

_EPHEMERAL_SECRET: str | None = None


def human_auth_enabled() -> bool:
    """Feature flag; default OFF so the server behaves exactly as before."""
    return (os.environ.get(HUMAN_AUTH_ENV) or "").strip().lower() in ("1", "true", "yes", "on")


def validate_human_auth_config() -> None:
    """Fail fast at startup when the feature is enabled but unusable.

    Called from the app lifespan. Disabled feature → no-op (existing
    deployments never see these checks).
    """
    if not human_auth_enabled():
        return
    # Raises in prod when the secret is missing or too short.
    jwt_secret()
    from api.google_auth import configured_client_ids

    if not configured_client_ids():
        raise RuntimeError(
            "DRISHTI_HUMAN_AUTH is enabled but DRISHTI_GOOGLE_CLIENT_IDS is empty. "
            "Set the accepted OAuth client IDs (comma-separated) so Google tokens "
            "for other applications cannot be replayed here."
        )
    logger.info("Human sign-in enabled (Google OAuth).")



def _env_is_prod() -> bool:
    return (os.environ.get("ENV", "dev") or "dev").strip().lower() == "prod"


def jwt_secret() -> str:
    """Resolve the signing secret, or raise when prod is misconfigured."""
    configured = (os.environ.get(JWT_SECRET_ENV) or "").strip()
    if configured:
        if len(configured) < 32:
            raise RuntimeError(
                f"{JWT_SECRET_ENV} must be at least 32 characters. "
                "Generate one with `python -c \"import secrets; print(secrets.token_urlsafe(48))\"`."
            )
        return configured
    if _env_is_prod():
        raise RuntimeError(
            f"ENV=prod but {JWT_SECRET_ENV} is not set. Refusing to issue "
            "human sessions without a stable signing secret."
        )
    global _EPHEMERAL_SECRET
    if _EPHEMERAL_SECRET is None:
        _EPHEMERAL_SECRET = secrets.token_urlsafe(48)
        logger.warning(
            "%s not set — using an ephemeral dev secret. Sessions reset on "
            "restart; NEVER use this in production.",
            JWT_SECRET_ENV,
        )
    return _EPHEMERAL_SECRET


class InvalidAppTokenError(RuntimeError):
    """The presented app token is missing, malformed, expired or forged."""


@dataclass(frozen=True)
class AppClaims:
    email: str
    role: str
    specialist_status: str | None


def issue_app_token(
    email: str,
    role: str,
    specialist_status: str | None = None,
    ttl_minutes: int | None = None,
) -> tuple[str, int]:
    """Issue a signed session token. Returns ``(token, expires_in_seconds)``."""
    if not email or "@" not in email:
        raise ValueError("a verified email is required to issue a session")
    ttl = MAX_TTL_MINUTES if ttl_minutes is None else max(1, min(int(ttl_minutes), MAX_TTL_MINUTES))
    now = datetime.now(timezone.utc)
    expires = now + timedelta(minutes=ttl)
    claims = {
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "sub": f"user:{email}",
        "email": email,
        "role": role,
        "specialist_status": specialist_status,
        "iat": int(now.timestamp()),
        "exp": int(expires.timestamp()),
    }
    token = jwt.encode(claims, jwt_secret(), algorithm="HS256")
    return token, ttl * 60


def decode_app_token(token: str) -> AppClaims:
    """Verify a session token. Raises :class:`InvalidAppTokenError`."""
    if not token or len(token) > 4096:
        raise InvalidAppTokenError("missing or oversized token")
    try:
        claims = jwt.decode(
            token,
            jwt_secret(),
            algorithms=["HS256"],
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
            options={"require": ["exp", "iat", "sub", "email", "role"]},
        )
    except jwt.PyJWTError as exc:
        logger.info("App token rejected (%s)", type(exc).__name__)
        raise InvalidAppTokenError("invalid session token") from exc
    email = (claims.get("email") or "").strip()
    role = (claims.get("role") or "").strip()
    if not email or "@" not in email or not role:
        raise InvalidAppTokenError("invalid session token")
    return AppClaims(
        email=email,
        role=role,
        specialist_status=claims.get("specialist_status"),
    )
