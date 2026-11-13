"""Free doctor notification via the WhatsApp Cloud API sandbox (Ticket D-3b).

WHY THIS CHANNEL: Meta's Cloud API has a free tier (test number + up to 5
verified recipients) — genuinely free for the hackathon demo, unlike Indian
transactional SMS which requires DLT registration (paid paperwork).

PRIVACY CONTRACT (docs/PRIVACY.md "what leaves the device"): the message
carries PSEUDONYM + GRADE ONLY — never name/phone/ABHA/village/image. The
doctor gets enough to triage; identity lives in the deid_screenings store,
which the doctor console can query by pseudonym.

OPERATIONS:
  - Disabled unless ALL three env vars are set:
      WHATSAPP_TOKEN            (permanent or sandbox token)
      WHATSAPP_PHONE_NUMBER_ID  (Meta dashboard)
      WHATSAPP_RECIPIENT        (doctor's WhatsApp number, with country code)
  - Fail-safe by design: notification failure NEVER fails the referral
    storage — the doctor console remains the source of truth.
"""

from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

GRAPH_URL_TEMPLATE = "https://graph.facebook.com/v21.0/{phone_number_id}/messages"
_TIMEOUT_SECONDS = 8.0

_TOKEN_ENV = "WHATSAPP_TOKEN"
_PHONE_ID_ENV = "WHATSAPP_PHONE_NUMBER_ID"
_RECIPIENT_ENV = "WHATSAPP_RECIPIENT"


def is_configured() -> bool:
    return all(
        (os.environ.get(v) or "").strip() for v in (_TOKEN_ENV, _PHONE_ID_ENV, _RECIPIENT_ENV)
    )


def build_message(item: dict[str, Any]) -> str:
    """De-identified referral summary. Field allowlist mirrors the wire
    contract — anything else here would be a privacy regression."""
    grade = item.get("dr_grade")
    label = item.get("dr_label") or ("grade %s" % grade if grade is not None else "ungraded")
    urgency = {
        4: "URGENT — within 48 hours",
        3: "PRIORITY — within 1 week",
    }.get(grade if grade is not None else -1, "Routine — within 4 weeks")
    review = "REVIEW REQUIRED" if item.get("requires_human_review") else "no flag"
    lines = [
        "Drishti-AI referral (de-identified)",
        "Screening: %s" % item.get("pseudo_screening_id", "?"),
        "Patient ref: %s" % item.get("pseudonym", "?"),
        "AI grade: %s (%s)" % (grade if grade is not None else "?", label),
        "Urgency: %s" % urgency,
        "Status: %s" % review,
        "Open the doctor console to view the image and over-read.",
    ]
    return "\n".join(lines)


def notify_doctor_referral(item: dict[str, Any]) -> dict[str, Any]:
    """Sends one WhatsApp notification. Returns a report dict; never raises.

    ``item`` must already be de-identified (the /sync/v2 schema guarantees
    it, but the allowlist here is defense in depth: only the keys below are
    read, so a smuggled field cannot reach the message body).
    """
    if not is_configured():
        return {"sent": False, "reason": "not_configured"}

    import httpx

    message = build_message(item)
    url = GRAPH_URL_TEMPLATE.format(phone_number_id=(os.environ.get(_PHONE_ID_ENV) or "").strip())
    headers = {
        "Authorization": "Bearer %s" % (os.environ.get(_TOKEN_ENV) or "").strip(),
        "Content-Type": "application/json",
    }
    body = {
        "messaging_product": "whatsapp",
        "to": (os.environ.get(_RECIPIENT_ENV) or "").strip(),
        "type": "text",
        "text": {"body": message},
    }
    try:
        response = httpx.post(url, headers=headers, json=body, timeout=_TIMEOUT_SECONDS)
        if response.status_code == 200:
            return {"sent": True, "message_id": response.json().get("messages", [{}])[0].get("id")}
        logger.warning(
            "WhatsApp notification rejected: %s %s",
            response.status_code,
            response.text[:200],
        )
        return {"sent": False, "reason": "http_%s" % response.status_code}
    except Exception as e:  # noqa: BLE001 - notification must never break storage
        logger.warning("WhatsApp notification failed: %s", e)
        return {"sent": False, "reason": type(e).__name__}
