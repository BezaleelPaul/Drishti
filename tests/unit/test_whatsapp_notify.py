"""Unit tests for the WhatsApp doctor-notification module (D-3b).

Covers: disabled-by-default behavior, payload construction (de-identified
allowlist), HTTP success/rejection paths, and fail-safe behavior (an
exception in the transport must never raise out of notify_doctor_referral).
"""

from __future__ import annotations

import pytest

from api.services import whatsapp_notify


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for key in (
        whatsapp_notify._TOKEN_ENV,
        whatsapp_notify._PHONE_ID_ENV,
        whatsapp_notify._RECIPIENT_ENV,
    ):
        monkeypatch.delenv(key, raising=False)
    yield


def _configure(monkeypatch):
    monkeypatch.setenv(whatsapp_notify._TOKEN_ENV, "test-token")
    monkeypatch.setenv(whatsapp_notify._PHONE_ID_ENV, "1234567890")
    monkeypatch.setenv(whatsapp_notify._RECIPIENT_ENV, "919999999999")


def test_not_configured_by_default():
    assert whatsapp_notify.is_configured() is False
    report = whatsapp_notify.notify_doctor_referral({"pseudo_screening_id": "SCR-X"})
    assert report == {"sent": False, "reason": "not_configured"}


def test_message_is_deidentified_allowlist_only():
    item = {
        "pseudo_screening_id": "SCR-AAAA0001",
        "pseudonym": "RSV-AB12CD34",
        "dr_grade": 3,
        "dr_label": "Severe NPDR",
        "requires_human_review": True,
        # Smuggled PHI must be IGNORED by the allowlist construction:
        "name": "Secret Patient",
        "phone": "9876543210",
        "village": "Shirur",
    }
    message = whatsapp_notify.build_message(item)
    assert "SCR-AAAA0001" in message
    assert "RSV-AB12CD34" in message
    assert "Severe NPDR" in message
    assert "PRIORITY" in message
    assert "Secret Patient" not in message
    assert "9876543210" not in message
    assert "Shirur" not in message


def test_send_posts_to_graph_api_and_reports_success(monkeypatch):
    _configure(monkeypatch)
    captured = {}

    class FakeResponse:
        status_code = 200

        def json(self):
            return {"messages": [{"id": "wamid.test"}]}

        @property
        def text(self):
            return "{}"

    def fake_post(url, headers=None, json=None, timeout=None):
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json
        return FakeResponse()

    monkeypatch.setattr("httpx.post", fake_post)
    report = whatsapp_notify.notify_doctor_referral(
        {
            "pseudo_screening_id": "SCR-AAAA0001",
            "pseudonym": "RSV-AB12CD34",
            "dr_grade": 4,
            "dr_label": "Proliferative DR",
            "requires_human_review": True,
        }
    )
    assert report["sent"] is True
    assert captured["url"].startswith("https://graph.facebook.com/v21.0/1234567890/messages")
    assert captured["headers"]["Authorization"] == "Bearer test-token"
    assert captured["json"]["messaging_product"] == "whatsapp"
    assert "URGENT" in captured["json"]["text"]["body"]


def test_http_rejection_is_reported_not_raised(monkeypatch):
    _configure(monkeypatch)

    class FakeResponse:
        status_code = 400

        def json(self):
            return {}

        text = '{"error":{}}'

    monkeypatch.setattr("httpx.post", lambda *a, **k: FakeResponse())
    report = whatsapp_notify.notify_doctor_referral({"pseudo_screening_id": "SCR-X"})
    assert report["sent"] is False
    assert report["reason"] == "http_400"


def test_transport_exception_never_raises(monkeypatch):
    _configure(monkeypatch)

    def boom(*a, **k):
        raise ConnectionError("no network")

    monkeypatch.setattr("httpx.post", boom)
    report = whatsapp_notify.notify_doctor_referral({"pseudo_screening_id": "SCR-X"})
    assert report["sent"] is False
    assert report["reason"] == "ConnectionError"
