"""Human sign-in routes (specialist/admin).

``POST /auth/google`` exchanges a verified Google ID token for a short-lived
app session token carrying the caller's role. Disabled (404) unless
``DRISHTI_HUMAN_AUTH`` is on, so a default deployment behaves exactly as
before this feature existed.

No patient data flows through this route; tokens carry identity + role only.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field

from api import specialists
from api.app_jwt import human_auth_enabled, issue_app_token
from api.auth import ApiPrincipal, _audit_row, authenticate, resolve_privileged_role
from api.google_auth import GoogleTokenError, verify_google_id_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


class GoogleSignInRequest(BaseModel):
    """Only the Google ID token is accepted — never profile fields."""

    id_token: str = Field(min_length=20, max_length=8192)


class SessionResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="Seconds until the token expires")
    role: str
    email: str
    specialist_status: str | None = None


class SessionInfoResponse(BaseModel):
    role: str
    email: str
    specialist_status: str | None = None


def _require_feature() -> None:
    if not human_auth_enabled():
        # 404 (not 403): the feature does not exist on this deployment.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found.")


@router.post("/google", response_model=SessionResponse)
def sign_in_with_google(payload: GoogleSignInRequest, request: Request) -> SessionResponse:
    """Verify a Google ID token and issue a role-bearing session token."""
    _require_feature()
    try:
        identity = verify_google_id_token(payload.id_token)
    except GoogleTokenError as exc:
        _audit_row("anonymous", "auth_failure", request.url.path, exc.reason)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Google sign-in could not be verified.",
        ) from exc

    specialist_status = specialists.status_for(identity.email)
    role, effective_status = resolve_privileged_role(identity.email, specialist_status)

    try:
        token, expires_in = issue_app_token(identity.email, role, effective_status)
    except RuntimeError as exc:
        # Misconfigured server (missing/short secret in prod). Never leak the
        # detail to the client; the operator sees the startup log instead.
        logger.error("Cannot issue session token: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Human sign-in is not configured on this server.",
        ) from exc

    _audit_row(f"user:{identity.email}", "auth.issue", request.url.path, f"role={role}")
    return SessionResponse(
        access_token=token,
        expires_in=expires_in,
        role=role,
        email=identity.email,
        specialist_status=effective_status,
    )


@router.get("/me", response_model=SessionInfoResponse)
def whoami(principal: ApiPrincipal = Depends(authenticate)) -> SessionInfoResponse:
    """Return the caller's session identity (JWT callers only)."""
    _require_feature()
    if principal.method != "app_jwt" or not principal.email:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="A human session token is required.",
        )
    return SessionInfoResponse(
        role=principal.role,
        email=principal.email,
        specialist_status=principal.specialist_status,
    )


__all__ = ["router"]
