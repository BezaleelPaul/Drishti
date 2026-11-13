"""
Dependency-free rate limiting + request-size guard for Drishti-AI.

- Sliding-window per identity (API key fingerprint when present, else client IP).
- General budget + stricter budget for heavy inference endpoints.
- Early 413 rejection when Content-Length exceeds the global cap.
"""
from __future__ import annotations

import os
import threading
import time
from collections import deque

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default


GENERAL_PER_MINUTE = _int_env("RATE_LIMIT_PER_MINUTE", 120)
INFERENCE_PER_MINUTE = _int_env("RATE_LIMIT_INFERENCE_PER_MINUTE", 20)
MAX_REQUEST_BYTES = _int_env("MAX_REQUEST_BYTES", 15 * 1024 * 1024)
# /sync batches carry up to 5 base64 images: the global cap would 413 honest
# batches, so sync gets its own Content-Length ceiling instead.
SYNC_MAX_BYTES = _int_env("SYNC_MAX_BYTES", 80 * 1024 * 1024)

# Upper bound on tracked identity buckets: the identity includes a hash of
# the presented API key, so random-key floods would otherwise grow _hits
# without limit (unauthenticated memory exhaustion).
MAX_TRACKED_BUCKETS = _int_env("RATE_LIMIT_MAX_BUCKETS", 20000)

# Heavy endpoints share a tighter bucket (each TF inference costs seconds).
INFERENCE_PREFIXES = ("/retinal/analyze", "/retinal/quality", "/sync", "/sync/")

# Never throttle these.
EXEMPT_PATHS = {"/", "/docs", "/redoc", "/openapi.json"}


class RateLimiter(BaseHTTPMiddleware):
    """In-memory sliding-window limiter. Single-process safe; use a shared
    store (Redis) if you scale past one uvicorn worker."""

    def __init__(self, app, general: int = GENERAL_PER_MINUTE, inference: int = INFERENCE_PER_MINUTE):
        super().__init__(app)
        self.general = general
        self.inference = inference
        self._lock = threading.Lock()
        self._hits: dict[tuple[str, str], deque[float]] = {}
        self._last_sweep = 0.0

    def _identity(self, request: Request) -> str:
        # Bucket on client IP, NOT the presented key: bucketing pre-auth on
        # an attacker-controlled header gives every random key a fresh
        # budget (limits never trip) and lets key floods multiply state.
        # Keyless callers previously also shared one global bucket that
        # ignored IP entirely; both failure modes are fixed by keying on IP.
        host = request.client.host if request.client else "unknown"
        return "ip:" + host

    def _sweep_expired(self, now: float, window: float = 60.0) -> None:
        cutoff = now - window
        stale = [k for k, dq in self._hits.items() if not dq or dq[-1] <= cutoff]
        for k in stale:
            del self._hits[k]

    def _allowed(self, bucket: str, limit: int, now: float, window: float = 60.0) -> tuple[bool, float]:
        with self._lock:
            # Amortized sweep (at most every 5s): sweeping the full dict on
            # every at-cap insert held the lock over an O(20k) scan per
            # request under flood, stalling the event loop.
            if now - self._last_sweep >= 5.0:
                self._sweep_expired(now, window)
                self._last_sweep = now
            dq = self._hits.get((bucket, str(limit)))
            if dq is None:
                if len(self._hits) >= MAX_TRACKED_BUCKETS:
                    self._sweep_expired(now, window)
                    self._last_sweep = now
                    if len(self._hits) >= MAX_TRACKED_BUCKETS:
                        # Still full under active flood: fail closed.
                        return False, window
                dq = self._hits.setdefault((bucket, str(limit)), deque())
            cutoff = now - window
            while dq and dq[0] <= cutoff:
                dq.popleft()
            if len(dq) >= limit:
                return False, dq[0] + window - now
            dq.append(now)
            return True, 0.0

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if path not in EXEMPT_PATHS:
            # Global request-size guard (per-endpoint caps still apply).
            # /sync batches legitimately exceed it, so they get their own
            # ceiling matched to the 5-item schema bound.
            cap = SYNC_MAX_BYTES if path.startswith(("/sync", "/sync/")) else MAX_REQUEST_BYTES
            try:
                length = int(request.headers.get("content-length", "0") or 0)
            except ValueError:
                length = 0
            if length > cap:
                return JSONResponse(
                    status_code=413,
                    content={"detail": f"Request too large (max {cap // (1024*1024)}MB)."},
                )
            is_inference = path.startswith(INFERENCE_PREFIXES)
            limit = self.inference if is_inference else self.general
            bucket = ("inf:" if is_inference else "gen:") + self._identity(request)
            ok, retry_after = self._allowed(bucket, limit, time.monotonic())
            if not ok:
                return JSONResponse(
                    status_code=429,
                    content={"detail": "Rate limit exceeded. Slow down and retry."},
                    headers={"Retry-After": str(max(1, int(retry_after)))},
                )
        return await call_next(request)
