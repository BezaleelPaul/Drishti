"""Unit tests for the DLT SMS gateway adapter (mirrors whatsapp tests)."""

from __future__ import annotations

import pytest

from api.services import sms_gateway


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for key in (
        sms_gateway._KEY_ENV,
        sms_gateway._TEMPLATE_ENV,
        sms_gateway._RECIPIENT_ENV,
        sms_gateway._URL_ENV,
    ):
        monkeypatch.delenv(key, raising=False)
    yield


def _configure(monkeypatch):
    monkeypatch.setenv(sms_gateway._KEY_ENV, "test-authkey")
    monkeypatch.setenv(sms_gateway._TEMPLATE_ENV, "tpl-001")
    monkeypatch.setenv(sms_gateway._RECIPIENT_ENV, "919999999999")


def test_not_configured_by_default():
    assert sms_gateway.is_configured() is False
    report = sms_gateway.send_doctor_sms({"pseudo_screening_id": "SCR-X"})
    assert report == {"sent": False, "reason": "not_configured"}


def test_variables_are_allowlist_only():
    item = {
        "pseudo_screening_id": "SCR-AAAA0001",
        "pseudonym": "RSV-AB12CD34",
        "dr_grade": 3,
        "dr_label": "Severe NPDR",
        "requires_human_review": True,
        "name": "Secret Patient",
        "phone": "9876543210",
    }
    variables = sms_gateway.build_variables(item)
    assert variables["PSEUDO"] == "RSV-AB12CD34"
    assert variables["SCRID"] == "SCR-AAAA0001"
    assert "Severe NPDR" in variables["GRADE"]
    assert "PRIORITY" in variables["URGENCY"]
    assert all("Secret Patient" not in v for v in variables.values())
    assert all("9876543210" not in v for v in variables.values())


def test_send_posts_msg91_flow_and_reports_success(monkeypatch):
    _configure(monkeypatch)
    captured = {}

    class FakeResponse:
        status_code = 200

        def json(self):
            return {"request_id": "req-1"}

        text = "{}"

    def fake_post(url, headers=None, json=None, timeout=None):
        captured.update(url=url, headers=headers, json=json)
        return FakeResponse()

    monkeypatch.setattr("httpx.post", fake_post)
    report = sms_gateway.send_doctor_sms(
        {
            "pseudo_screening_id": "SCR-AAAA0001",
            "pseudonym": "RSV-AB12CD34",
            "dr_grade": 3,
            "dr_label": "Severe NPDR",
            "requires_human_review": True,
        }
    )
    assert report["sent"] is True
    assert report["request_id"] == "req-1"
    assert captured["url"] == sms_gateway.MSG91_FLOW_URL
    assert captured["headers"]["authkey"] == "test-authkey"
    recipient = captured["json"]["recipients"][0]
    assert recipient["mobiles"] == "919999999999"
    assert recipient["PSEUDO"] == "RSV-AB12CD34"
    assert captured["json"]["template_id"] == "tpl-001"


def test_http_rejection_is_reported_not_raised(monkeypatch):
    _configure(monkeypatch)

    class FakeResponse:
        status_code = 402

        def json(self):
            return {}

        text = "quota"

    monkeypatch.setattr("httpx.post", lambda *a, **k: FakeResponse())
    report = sms_gateway.send_doctor_sms({"pseudo_screening_id": "SCR-X"})
    assert report == {"sent": False, "reason": "http_402"}


def test_transport_exception_never_raises(monkeypatch):
    _configure(monkeypatch)

    def boom(*a, **k):
        raise TimeoutError("gateway timeout")

    monkeypatch.setattr("httpx.post", boom)
    report = sms_gateway.send_doctor_sms({"pseudo_screening_id": "SCR-X"})
    assert report["sent"] is False
    assert report["reason"] == "TimeoutError"
