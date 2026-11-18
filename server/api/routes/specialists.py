"""Specialist application and admin approval routes (T6-T7, audit T8).

Workflow:
    signed-in user → POST /specialists/apply → pending
    admin → GET /admin/specialists?status=pending
    admin → POST /admin/specialists/{id}/decide {decision: approve|reject}
    approved → next /auth/google issues a `doctor` session

Human endpoints require an app session (not an API key): an API key is a
device credential and must never author clinical qualifications.
"""

from __future__ import annotations

import logging
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field, field_validator

from api import specialists
from api.app_jwt import human_auth_enabled
from api.auth import ApiPrincipal, _audit_row, authenticate, require_admin

logger = logging.getLogger(__name__)


def _feature_gate() -> None:
    """404 before any credential check: a disabled feature does not exist."""
    if not human_auth_enabled():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found.")


router = APIRouter(
    prefix="/specialists", tags=["specialists"], dependencies=[Depends(_feature_gate)]
)
admin_router = APIRouter(
    prefix="/admin/specialists", tags=["specialists"], dependencies=[Depends(_feature_gate)]
)

_COUNCIL_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9/\- ]{2,63}$"


class ApplicationRequest(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    council_reg_no: str = Field(min_length=3, max_length=64, pattern=_COUNCIL_PATTERN)
    specialty: str = Field(min_length=2, max_length=80)
    license_ref: Optional[str] = Field(default=None, max_length=200)

    @field_validator("full_name", "specialty")
    @classmethod
    def _strip(cls, value: str) -> str:
        cleaned = value.strip()
        if len(cleaned) < 2:
            raise ValueError("must contain at least 2 non-space characters")
        return cleaned


class DecisionRequest(BaseModel):
    decision: Literal["approve", "reject"]
    note: Optional[str] = Field(default=None, max_length=500)


class ApplicationResponse(BaseModel):
    id: int
    email: str
    full_name: str
    council_reg_no: str
    specialty: str
    license_ref: Optional[str] = None
    status: str
    submitted_at: str
    decided_at: Optional[str] = None
    decided_by: Optional[str] = None
    decision_note: Optional[str] = None


class MyApplicationResponse(BaseModel):
    application: Optional[ApplicationResponse] = None
    can_reapply_at: Optional[str] = None


def _require_human(principal: ApiPrincipal) -> None:
    """Applications are a person's professional record — not a device's."""
    if principal.method != "app_jwt" or not principal.email:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="A signed-in human session is required for this action.",
        )


def _public(record: dict) -> ApplicationResponse:
    """Project a stored row, excluding license references from listings."""
    return ApplicationResponse(
        id=int(record["id"]),
        email=str(record["email"]),
        full_name=str(record["full_name"]),
        council_reg_no=str(record["council_reg_no"]),
        specialty=str(record["specialty"]),
        license_ref=record.get("license_ref"),
        status=str(record["status"]),
        submitted_at=str(record["submitted_at"]),
        decided_at=record.get("decided_at"),
        decided_by=record.get("decided_by"),
        decision_note=record.get("decision_note"),
    )


@router.post("/apply", response_model=ApplicationResponse, status_code=status.HTTP_201_CREATED)
def apply_for_specialist(
    payload: ApplicationRequest,
    request: Request,
    principal: ApiPrincipal = Depends(authenticate),
) -> ApplicationResponse:
    """Submit a specialist application for admin review."""
    _require_human(principal)
    try:
        record = specialists.apply_for_specialist(
            email=principal.email or "",
            full_name=payload.full_name,
            council_reg_no=payload.council_reg_no,
            specialty=payload.specialty,
            license_ref=payload.license_ref,
        )
    except specialists.AlreadyApprovedError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
    except specialists.DuplicatePendingError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
    except specialists.CooldownError as exc:
        _audit_row(f"user:{principal.email}", "specialist.apply_blocked", request.url.path, exc.code)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Re-application is available after {exc.retry_at}.",
        ) from exc

    _audit_row(f"user:{principal.email}", "specialist.apply", request.url.path, f"id={record['id']}")
    return _public(record)


@router.get("/me", response_model=MyApplicationResponse)
def my_application(principal: ApiPrincipal = Depends(authenticate)) -> MyApplicationResponse:
    """Current application state for the signed-in user."""
    _require_human(principal)
    record = specialists.latest_for_email(principal.email or "")
    if record is None:
        return MyApplicationResponse()
    return MyApplicationResponse(
        application=_public(record),
        can_reapply_at=specialists._cooldown_retry_at(record),
    )


@admin_router.get("", response_model=list[ApplicationResponse])
def list_applications(
    status_filter: Optional[Literal["pending", "approved", "rejected"]] = Query(
        default=None, alias="status"
    ),
    principal: ApiPrincipal = Depends(require_admin),
) -> list[ApplicationResponse]:
    """Admin: list applications, optionally filtered by status."""
    return [_public(record) for record in specialists.list_applications(status_filter)]


@admin_router.post("/{application_id}/decide", response_model=ApplicationResponse)
def decide_application(
    application_id: int,
    payload: DecisionRequest,
    request: Request,
    principal: ApiPrincipal = Depends(require_admin),
) -> ApplicationResponse:
    """Admin: approve or reject a pending application."""
    approve = payload.decision == "approve"
    try:
        record = specialists.decide_application(
            application_id,
            approve=approve,
            actor=principal.actor,
            note=payload.note or "",
        )
    except specialists.ApplicationNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except specialists.ApplicationStateError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc

    _audit_row(
        principal.actor,
        "specialist.decide",
        request.url.path,
        f"id={application_id} decision={record['status']}",
    )
    return _public(record)


__all__ = ["router", "admin_router"]
