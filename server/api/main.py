"""
Netra-AI / Drishti-AI: FastAPI Application Entry Point.
Binds Flutter Mobile/Tablet/Web frontend to the Python AI Screening Pipeline.
"""

from __future__ import annotations

import logging
import os
import sys
from contextlib import asynccontextmanager
from datetime import datetime, timezone

# Ensure repository root is in sys.path
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PROJECT_ROOT not in sys.path:
    sys.path.insert(0, _PROJECT_ROOT)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles

from api.auth import ENV, IS_PROD, active_key_count, uses_dev_keys
from api.database import ensure_db
from api.ratelimit import RateLimiter
from api.routes.patients import router as patients_router
from api.routes.results import router as results_router
from api.routes.retinal import router as retinal_router
from api.routes.review import router as review_router
from api.routes.risk import router as risk_router
from api.routes.sync import router as sync_router
from api.routes.sync_v2 import router as sync_v2_router
from api.routes.system import router as system_router

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: initialize schema (idempotent, race-safe for multi-worker boot).
    ensure_db()
    # The __main__ runner refuses dev keys on LAN, but `uvicorn api.main:app
    # --host 0.0.0.0` bypasses it entirely: enforce here so every serve path
    # is covered. NOTE: the HOST env var is NOT authoritative (uvicorn CLI
    # flags don't set it), so also parse --host out of sys.argv.
    host = os.environ.get("HOST", "127.0.0.1")
    for _i, _arg in enumerate(sys.argv):
        if _arg == "--host" and _i + 1 < len(sys.argv):
            host = sys.argv[_i + 1]
        elif _arg.startswith("--host="):
            host = _arg.split("=", 1)[1]
        elif _arg in ("-b", "--bind") and _i + 1 < len(sys.argv):
            # gunicorn/hypercorn bind flag: may be "addr:port" or "addr".
            host = sys.argv[_i + 1].rsplit(":", 1)[0].strip("[]") or host
        elif _arg.startswith("--bind="):
            host = _arg.split("=", 1)[1].rsplit(":", 1)[0].strip("[]") or host
    if uses_dev_keys() and not _is_loopback(host):
        raise RuntimeError(
            f"Refusing to serve {host} with built-in DEV API keys. Set "
            "DRISHTI_API_KEYS with real keys (and ENV=prod) for network exposure."
        )
    logger.info("Drishti-AI API startup complete (env=%s, api_keys=%d).", ENV, active_key_count())
    yield
    # Shutdown: checkpoint the WAL so a `docker stop` does not leave -wal/-shm
    # files uncheckpointed (slower next boot, larger disk footprint).
    try:
        from api.database import get_connection

        conn = get_connection()
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.commit()
        finally:
            conn.close()
    except Exception as e:  # noqa: BLE001 - shutdown checkpoint must not block exit
        logger.warning("WAL checkpoint on shutdown failed: %s", e)


def _is_loopback(host: str) -> bool:
    return host in ("127.0.0.1", "localhost", "::1")


app = FastAPI(
    title="Netra-AI Clinical Screening API",
    description=(
        "Production-oriented REST API connecting Flutter applications to the "
        "Diabetic Retinopathy Screening Pipeline (Model 1 Quality Gate, "
        "Model 2 EfficientNetB0 Classifier, Grad-CAM++, and Diabetes Risk Engine)."
    ),
    version="2.0.0",
    # Interactive docs enumerate every route/schema: never expose them
    # unauthenticated in production.
    docs_url=None if IS_PROD else "/docs",
    redoc_url=None if IS_PROD else "/redoc",
    lifespan=lifespan,
)

# -----------------------------------------------------------------------------
# Rate limiting + request-size guard (runs before auth so abuse is cut early)
# -----------------------------------------------------------------------------
app.add_middleware(RateLimiter)
app.add_middleware(GZipMiddleware, minimum_size=1024)


# -----------------------------------------------------------------------------
# CORS: explicit allowlist only. Wildcard origins + credentials is both broken
# (browsers reject it) and a PHI exfiltration vector. Configure via:
#   CORS_ORIGINS="https://app.example.com,https://clinic.example.org"
#   CORS_ALLOW_CREDENTIALS=true   (only if cookies/Authorization are needed)
# -----------------------------------------------------------------------------
def _cors_origins() -> list[str]:
    raw = os.environ.get("CORS_ORIGINS", "").strip()
    if raw:
        origins = [o.strip() for o in raw.split(",") if o.strip()]
        if "*" in origins:
            # A wildcard origin must never be combined with credentials, and
            # must be an explicit opt-in (it exposes unauthenticated reads to
            # any website the operator visits).
            if os.environ.get("CORS_ALLOW_WILDCARD", "false").lower() != "true":
                raise RuntimeError(
                    "CORS_ORIGINS contains '*'. Refusing to start: use an explicit "
                    "origin allowlist, or set CORS_ALLOW_WILDCARD=true (dev only, "
                    "never with CORS_ALLOW_CREDENTIALS=true)."
                )
            if os.environ.get("CORS_ALLOW_CREDENTIALS", "false").lower() == "true":
                raise RuntimeError(
                    "CORS_ORIGINS='*' with CORS_ALLOW_CREDENTIALS=true is "
                    "rejected: browsers refuse it and it widens PHI reads. "
                    "Use an explicit origin allowlist with credentials."
                )
            return ["*"]
        return origins
    # Dev defaults: local Flutter runners only.
    return [
        "http://localhost:3000",
        "http://localhost:8080",
        "http://localhost:5000",
        "http://localhost:8000",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:8080",
        "http://127.0.0.1:5000",
        "http://127.0.0.1:8000",
    ]


_allow_credentials = os.environ.get("CORS_ALLOW_CREDENTIALS", "false").lower() == "true"
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins(),
    allow_credentials=_allow_credentials,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-API-Key"],
)

# -----------------------------------------------------------------------------
# Static assets (non-PHI only). Screening result images are NOT mounted here;
# they are served authenticated via /results/{screening_id}/{file}.
# -----------------------------------------------------------------------------
flutter_web_dir = os.path.join(_PROJECT_ROOT, "flutter_app", "build", "web")

if os.path.exists(flutter_web_dir):
    app.mount("/app", StaticFiles(directory=flutter_web_dir, html=True), name="flutter_app")


# -----------------------------------------------------------------------------
# Request-validation 422s MUST NOT echo the offending values. Pydantic's
# default error body includes an `input` field containing the raw value —
# on /sync/v2 that would leak exactly the PHI the endpoint exists to keep
# off the server (fail-closed contract, Ticket C-4). Redact globally: the
# field location (loc) and error type are kept, the value is dropped.
# -----------------------------------------------------------------------------
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


@app.exception_handler(RequestValidationError)
async def _redacted_validation_handler(request, exc: RequestValidationError):
    errors = []
    for err in exc.errors():
        redacted = dict(err)
        redacted.pop("input", None)
        errors.append(redacted)
    # Parse-time rejections on the de-identified sync path are audit-logged
    # too (field NAMES only — the redacted errors carry no values), so an
    # attempted PHI smuggle cannot bypass the audit trail by being
    # malformed (Ticket C-4 contract: every rejection is logged).
    if request.url.path == "/sync/v2":
        try:
            from api.database import get_db

            with get_db() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "INSERT INTO audit_log (actor, action, resource, detail, created_at) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (
                        "deid-sync",
                        "deid_sync_rejected",
                        "parse-time",
                        ";".join(f"loc={err.get('loc')},type={err.get('type')}" for err in errors)[
                            :400
                        ],
                        datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                    ),
                )
                conn.commit()
        except Exception:  # audit best-effort, never block the 422
            logger.debug("Audit log write for parse-time rejection failed", exc_info=True)
    return JSONResponse(status_code=422, content={"detail": errors})


# -----------------------------------------------------------------------------
# Include API Routers
# -----------------------------------------------------------------------------
app.include_router(system_router)
app.include_router(patients_router)
app.include_router(risk_router)
app.include_router(retinal_router)
app.include_router(review_router)
app.include_router(sync_router)
app.include_router(sync_v2_router)
app.include_router(results_router)


@app.get("/")
def root():
    return {
        "platform": "Netra-AI Rural Health Screening Engine",
        "api_version": "2.0.0",
        "status": "up",
        "auth": "X-API-Key header required (except /, /cameras, /samples)",
        "architecture": "Flutter Frontend <-> FastAPI Bridge <-> Python AI Pipeline",
        "supported_cameras": "Manufacturer-Agnostic (Any JPG/PNG Fundus Camera)",
    }


if __name__ == "__main__":
    import uvicorn

    # Safe defaults: loopback bind always; LAN exposure is an explicit
    # HOST=0.0.0.0 opt-in. Refuse well-known dev keys on a non-loopback
    # interface (fail-closed against 'forgot ENV=prod' deployments).
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8000"))
    if uses_dev_keys() and not _is_loopback(host):
        raise RuntimeError(
            f"Refusing to bind {host} with built-in DEV API keys. Set "
            "DRISHTI_API_KEYS with real keys (and ENV=prod) for network exposure."
        )
    reload = os.environ.get("RELOAD", "false").lower() == "true" and not IS_PROD
    uvicorn.run("api.main:app", host=host, port=port, reload=reload)
