"""Startup validation for the human-auth feature (T4)."""

from __future__ import annotations

import pytest

from api.app_jwt import human_auth_enabled, validate_human_auth_config


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in (
        "DRISHTI_HUMAN_AUTH",
        "DRISHTI_JWT_SECRET",
        "DRISHTI_GOOGLE_CLIENT_IDS",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.delenv("ENV", raising=False)


def test_flag_defaults_to_off() -> None:
    assert human_auth_enabled() is False


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "on"])
def test_flag_accepts_documented_values(monkeypatch, value: str) -> None:
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", value)
    assert human_auth_enabled() is True


def test_validation_is_noop_when_disabled() -> None:
    # No secret, no client IDs — but the feature is off, so this must pass.
    validate_human_auth_config()


def test_enabled_without_client_ids_fails_fast(monkeypatch) -> None:
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", "1")
    monkeypatch.setenv("DRISHTI_JWT_SECRET", "x" * 40)
    with pytest.raises(RuntimeError, match="CLIENT_IDS"):
        validate_human_auth_config()


def test_prod_enabled_without_secret_fails_fast(monkeypatch) -> None:
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", "1")
    monkeypatch.setenv("DRISHTI_GOOGLE_CLIENT_IDS", "client.apps.googleusercontent.com")
    monkeypatch.setenv("ENV", "prod")
    with pytest.raises(RuntimeError, match="DRISHTI_JWT_SECRET"):
        validate_human_auth_config()


def test_fully_configured_passes(monkeypatch) -> None:
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", "1")
    monkeypatch.setenv("DRISHTI_JWT_SECRET", "x" * 40)
    monkeypatch.setenv("DRISHTI_GOOGLE_CLIENT_IDS", "client.apps.googleusercontent.com")
    validate_human_auth_config()
