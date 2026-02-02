from __future__ import annotations

import os
from typing import Iterable

from fastapi import FastAPI
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import Response


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    def __init__(
        self,
        app,
        *,
        hsts_seconds: int = 31536000,
        include_subdomains: bool = True,
        preload: bool = False,
    ) -> None:
        super().__init__(app)
        self._hsts_seconds = hsts_seconds
        self._include_subdomains = include_subdomains
        self._preload = preload

    async def dispatch(self, request: Request, call_next) -> Response:
        response = await call_next(request)

        # Basic hardening headers (safe defaults)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault(
            "Permissions-Policy",
            "geolocation=(), microphone=(), camera=()",
        )

        # HSTS: enable only when behind HTTPS.
        if self._hsts_seconds > 0:
            parts = [f"max-age={self._hsts_seconds}"]
            if self._include_subdomains:
                parts.append("includeSubDomains")
            if self._preload:
                parts.append("preload")
            response.headers.setdefault("Strict-Transport-Security", "; ".join(parts))

        return response


def _split_csv(val: str) -> list[str]:
    return [x.strip() for x in (val or "").split(",") if x.strip()]


def setup_hardening(app: FastAPI) -> None:
    """Optional production hardening.

    Controlled by env vars (kept outside Settings to avoid config churn across services):
    - SB_HARDENING_ENABLED=1
    - SB_HSTS_SECONDS (default 31536000)
    - SB_HSTS_PRELOAD=0
    - SB_CORS_ALLOW_ORIGINS (comma-separated)

    TLS termination should be handled by a reverse proxy / gateway.
    """

    if os.getenv("SB_HARDENING_ENABLED", "0").strip() != "1":
        return

    hsts_seconds = int(os.getenv("SB_HSTS_SECONDS", "31536000"))
    preload = os.getenv("SB_HSTS_PRELOAD", "0").strip() == "1"

    app.add_middleware(
        SecurityHeadersMiddleware,
        hsts_seconds=hsts_seconds,
        include_subdomains=True,
        preload=preload,
    )

    origins = _split_csv(os.getenv("SB_CORS_ALLOW_ORIGINS", ""))
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", "X-API-Key", "X-Trace-Id", "X-App-Uuid"],
        )
