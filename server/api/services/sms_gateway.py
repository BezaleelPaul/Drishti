"""DLT-legal SMS gateway adapter (production channel, Ticket D-3c).

This is the TRAI-sanctioned automated SMS route for India: a registered
gateway (MSG91-class) with your approved DLT entity, header and template.
Legal ONLY after DLT registration — see docs/PRIVACY.md and the team plan.

CONNECTION (env vars, all required or the adapter stays off):
  SMS_GATEWAY_KEY      your gateway auth key (MSG91 "authkey")
  SMS_TEMPLATE_ID      your approved DLT template id (with named variables)
  SMS_RECIPIENT        doctor's mobile with country code (91XXXXXXXXXX)
  Optional:
  SMS_GATEWAY_URL      override endpoint (default: MSG91 flow v5)
  SMS_DLT_HEADER       your registered header (some gateways want it)

MESSAGE CONTENT: pseudonym + grade + urgency only (same allowlist rules as
the WhatsApp notifier) — the DLT template variables carry no PHI. Fail-safe:
any transport error is reported, never raised; the referral store is the
source of truth. The adapter stays OFF until every required env var exists.
"""

from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

MSG91_FLOW_URL = "https://control.msg91.com/api/v5/flow/"
_TIMEOUT_SECONDS = 8.0

_KEY_ENV = "SMS_GATEWAY_KEY"
_TEMPLATE_ENV = "SMS_TEMPLATE_ID"
_RECIPIENT_ENV = "SMS_RECIPIENT"
_URL_ENV = "SMS_GATEWAY_URL"


def is_configured() -> bool:
    return all((os.environ.get(v) or "").strip() for v in (_KEY_ENV, _TEMPLATE_ENV, _RECIPIENT_ENV))


def build_variables(item: dict[str, Any]) -> dict[str, str]:
    """DLT template variables — allowlist only, pseudonym-safe by
    construction: a smuggled PHI key in ``item`` cannot reach the dict."""
    grade = item.get("dr_grade")
    label = item.get("dr_label") or ("grade %s" % grade if grade is not None else "ungraded")
    urgency = {
        4: "URGENT 48 hours",
        3: "PRIORITY 1 week",
    }.get(grade if grade is not None else -1, "ROUTINE 4 weeks")
    return {
        "PSEUDO": str(item.get("pseudonym", "?")),
        "SCRID": str(item.get("pseudo_screening_id", "?")),
        "GRADE": "%s (%s)" % (grade if grade is not None else "?", label),
        "URGENCY": urgency,
    }


def send_doctor_sms(item: dict[str, Any]) -> dict[str, Any]:
    """Sends one DLT-template SMS. Returns a report dict; never raises."""
    if not is_configured():
        return {"sent": False, "reason": "not_configured"}

    import httpx

    url = (os.environ.get(_URL_ENV) or "").strip() or MSG91_FLOW_URL
    headers = {
        "authkey": (os.environ.get(_KEY_ENV) or "").strip(),
        "Content-Type": "application/json",
    }
    body = {
        "template_id": (os.environ.get(_TEMPLATE_ENV) or "").strip(),
        "short_url": "0",
        "recipients": [
            {
                "mobiles": (os.environ.get(_RECIPIENT_ENV) or "").strip(),
                **build_variables(item),
            }
        ],
    }
    try:
        response = httpx.post(url, headers=headers, json=body, timeout=_TIMEOUT_SECONDS)
        if response.status_code == 200:
            payload = response.json()
            return {
                "sent": True,
                "request_id": payload.get("request_id") or payload.get("message") or "accepted",
            }
        logger.warning("SMS gateway rejected: %s %s", response.status_code, response.text[:200])
        return {"sent": False, "reason": "http_%s" % response.status_code}
    except Exception as e:  # noqa: BLE001 - notification must never break storage
        logger.warning("SMS gateway failed: %s", e)
        return {"sent": False, "reason": type(e).__name__}
