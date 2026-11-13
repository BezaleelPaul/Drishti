"""
Authenticated serving of screening result images (original + Grad-CAM overlay).

Replaces the previous world-readable `/static/results` mount: screening IDs are
short and enumerable, so these files must require a valid API key.
"""
from __future__ import annotations

import os
import re

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from api.auth import ApiPrincipal, audit_action, require_auth

router = APIRouter(prefix="/results", tags=["Screening Result Files"])

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_RESULTS_DIR = os.path.join(_PROJECT_ROOT, "results", "api_screenings")

_SCREENING_ID_RE = re.compile(r"^SCR-[A-Z0-9]{6,}$")
_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,128}\.(jpg|jpeg|png)$", re.IGNORECASE)


@router.get("/{screening_id}/{filename}")
def get_result_file(
    screening_id: str,
    filename: str,
    _principal: ApiPrincipal = Depends(require_auth),
):
    """Serve one result image for a screening. Auth required; path traversal
    impossible (strict allowlist + realpath containment check)."""
    if not _SCREENING_ID_RE.match(screening_id):
        audit_action(_principal, "result_read_404", f"{screening_id}/{filename}")
        raise HTTPException(status_code=404, detail="Result not found.")
    if not _SAFE_NAME_RE.match(filename):
        audit_action(_principal, "result_read_404", f"{screening_id}/{filename}")
        raise HTTPException(status_code=404, detail="Result not found.")
    candidate = os.path.realpath(os.path.join(_RESULTS_DIR, screening_id, filename))
    base = os.path.realpath(_RESULTS_DIR)
    if not candidate.startswith(base + os.sep) or not os.path.isfile(candidate):
        # Audit misses too: only logging successes would let an authenticated
        # key enumerate IDs without leaving a trace.
        audit_action(_principal, "result_read_404", f"{screening_id}/{filename}")
        raise HTTPException(status_code=404, detail="Result not found.")
    audit_action(
        _principal, "result_read", f"{screening_id}/{filename}",
    )
    media = "image/png" if filename.lower().endswith(".png") else "image/jpeg"
    return FileResponse(candidate, media_type=media)
