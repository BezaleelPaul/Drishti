"""Google ID-token verification for Drishti human sign-in.

Trust rules (fail closed):
  * signature validated by Google's published keys
  * issuer must be ``accounts.google.com`` / ``https://accounts.google.com``
  * audience must be one of the configured OAuth client IDs
  * token must not be expired
  * the email claim must be present and verified

The Google verifier object is reused process-wide so its certificate cache
survives between requests (no JWKS fetch per sign-in).

This module never logs token contents. Failures are raised as
:class:`GoogleTokenError` with a short, non-sensitive reason.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

logger = logging.getLogger(__name__)

GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}

#: Comma-separated OAuth client IDs accepted for this deployment.
CLIENT_IDS_ENV = "DRISHTI_GOOGLE_CLIENT_IDS"

# Google's verifier request object (lazy; caches published certificates).
_REQUEST = None


class GoogleTokenError(RuntimeError):
    """Verification failed. ``reason`` is safe to return to a client."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class GoogleIdentity:
    """Verified Google identity — the minimum needed to map a role."""

    subject: str
    email: str


def configured_client_ids() -> list[str]:
    """Accepted Google OAuth client IDs (blank entries dropped)."""
    raw = os.environ.get(CLIENT_IDS_ENV, "")
    return [part.strip() for part in raw.split(",") if part.strip()]


def _verify_with_google(token: str, audiences: list[str]) -> dict:
    """Call Google's verifier. Kept separate so tests can substitute it."""
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token as google_id_token

    global _REQUEST
    if _REQUEST is None:
        # Reused across requests so the certificate cache stays warm.
        _REQUEST = google_requests.Request()
    return google_id_token.verify_oauth2_token(token, _REQUEST, audience=audiences)


def verify_google_id_token(token: str, audiences: list[str] | None = None) -> GoogleIdentity:
    """Verify a Google ID token and return its identity.

    Raises :class:`GoogleTokenError` for a missing configuration, a bad
    token, or an unverified email. Never returns a partially trusted
    identity.
    """
    if not token or not isinstance(token, str):
        raise GoogleTokenError("missing token")
    accepted = audiences if audiences is not None else configured_client_ids()
    if not accepted:
        raise GoogleTokenError("google sign-in is not configured on this server")

    try:
        claims = _verify_with_google(token, accepted)
    except Exception as exc:  # noqa: BLE001 - google-auth raises ValueError subclasses
        # Reason strings stay generic: no token material, no claim echo.
        logger.info("Google token rejected (%s)", type(exc).__name__)
        raise GoogleTokenError("token verification failed") from exc

    issuer = claims.get("iss")
    if issuer not in GOOGLE_ISSUERS:
        raise GoogleTokenError("token verification failed")
    email = (claims.get("email") or "").strip()
    if not email:
        raise GoogleTokenError("token has no email claim")
    if not claims.get("email_verified", False):
        raise GoogleTokenError("google email is not verified")
    subject = (claims.get("sub") or "").strip()
    if not subject:
        raise GoogleTokenError("token has no subject claim")
    return GoogleIdentity(subject=subject, email=email.lower())
