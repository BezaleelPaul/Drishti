import os

from fastapi.testclient import TestClient

from api.auth import ApiPrincipal, require_role
from api.database import _resolve_db_path
from api.main import app

client = TestClient(app, raise_server_exceptions=False)
OPERATOR_HEADERS = {"X-API-Key": "dev-operator-key"}


def test_diabetes_risk_returns_provenance_for_rule_path():
    response = client.post(
        "/diabetes-risk",
        headers=OPERATOR_HEADERS,
        json={
            "age": 52,
            "gender": "Female",
            "bmi": 27.2,
            "family_history": True,
            "known_diabetes_years": 4,
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["risk_source"] == "clinical_rule"
    assert body["risk_level"] == "HIGH"


def test_diabetes_risk_rejects_impossible_zero_age():
    response = client.post(
        "/diabetes-risk",
        headers=OPERATOR_HEADERS,
        json={
            "age": 0,
            "gender": "Female",
            "bmi": 22.0,
            "family_history": False,
        },
    )

    assert response.status_code == 422


def test_diabetes_risk_returns_provenance_for_model_or_fallback_path():
    response = client.post(
        "/diabetes-risk",
        headers=OPERATOR_HEADERS,
        json={
            "age": 35,
            "gender": "Female",
            "bmi": 22.0,
            "family_history": False,
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["risk_source"] in {"ml", "heuristic"}


def test_status_reports_unavailable_clinical_backend():
    response = client.get("/status", headers=OPERATOR_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    from api.services.ai_bridge import AIBridge

    if AIBridge.get_instance().dr_classifier.get_backend() == "simulated":
        assert body["ai_engine"].startswith("Degraded")
        assert "UNAVAILABLE" in body["models_loaded"]["Model 2 (DR Classifier)"]


def test_status_does_not_initialize_ai_bridge(monkeypatch):
    from api.services.ai_bridge import AIBridge

    monkeypatch.setattr(AIBridge, "_instance", None)
    response = client.get("/status", headers=OPERATOR_HEADERS)

    assert response.status_code == 200, response.text
    assert AIBridge._instance is None
    assert response.json()["ai_engine"].startswith("Ready")


def test_admin_key_can_access_doctor_review_queue():
    response = client.get("/review/pending", headers={"X-API-Key": "dev-admin-key"})

    assert response.status_code == 200, response.text
    body = response.json()
    assert "total_pending" in body
    assert "items" in body


def test_role_hierarchy_allows_higher_roles_for_lower_minimums():
    assert require_role("doctor").__closure__ is not None

    assert ApiPrincipal("fp-doctor", "doctor").role == "doctor"
    assert ApiPrincipal("fp-admin", "admin").role == "admin"

    from api.auth import _role_allows

    assert _role_allows("doctor", "doctor") is True
    assert _role_allows("admin", "doctor") is True
    assert _role_allows("admin", "admin") is True
    assert _role_allows("doctor", "admin") is False


def test_empty_db_path_falls_back_to_default_location():
    expected = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "data",
        "screening_platform.db",
    )
    assert _resolve_db_path("") == expected


def test_dashboard_screenings_requires_auth():
    response = client.get("/screenings")

    assert response.status_code in (401, 403)


def test_dashboard_screenings_returns_stats_and_recent_items():
    response = client.get("/screenings", headers=OPERATOR_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    stats = body["stats"]
    for key in (
        "today_screenings",
        "awaiting_specialist",
        "urgent_referrals",
        "total_screenings",
    ):
        assert isinstance(stats[key], int)
        assert stats[key] >= 0
    assert stats["today_screenings"] <= stats["total_screenings"]
    assert isinstance(body["items"], list)
    assert len(body["items"]) <= 50
    for item in body["items"]:
        for key in ("screening_id", "patient_id", "created_at", "result_text", "status"):
            assert key in item
        assert item["status"] in {
            "verified",
            "referral",
            "awaiting_specialist",
            "rejected",
        }
        assert item["result_text"]
