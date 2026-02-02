from __future__ import annotations

import re
import threading
import time
from dataclasses import dataclass
from typing import Iterable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response


_RATE_RE = re.compile(r"^\s*(?P<count>\d+)\s*/\s*(?P<window>\d+)(?P<unit>[smh]?)\s*$")


@dataclass(frozen=True)
class Rate:
    limit: int
    window_seconds: int


def parse_rate(spec: str) -> Rate:
    """Parse a rate spec like `60/60`, `100/1m`, `1000/1h`.

    Meaning: allow `limit` requests per `window_seconds`.
    """

    m = _RATE_RE.match(spec or "")
    if not m:
        raise ValueError(f"invalid rate spec: {spec!r}")

    limit = int(m.group("count"))
    window = int(m.group("window"))
    unit = m.group("unit") or "s"

    mult = {"s": 1, "m": 60, "h": 3600}[unit]
    window_seconds = window * mult

    if limit <= 0 or window_seconds <= 0:
        raise ValueError(f"invalid rate spec: {spec!r}")

    return Rate(limit=limit, window_seconds=window_seconds)


@dataclass(frozen=True)
class Rule:
    method: str
    path: str
    rate: Rate

    def matches(self, request: Request) -> bool:
        if self.method != "*" and request.method.upper() != self.method:
            return False

        req_path = request.url.path

        # Prefix match if configured as "/v1/*" or "/v1/metrics/*"
        if self.path.endswith("/*"):
            prefix = self.path[:-1]  # keep trailing '/'
            return req_path.startswith(prefix)

        return req_path == self.path


class _FixedWindowInMemory:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._buckets: dict[str, tuple[int, int]] = {}
        # key -> (window_start_epoch, count)

    def hit(self, key: str, rate: Rate) -> tuple[bool, int, int]:
        """Return (allowed, remaining, reset_epoch_seconds)."""

        now = int(time.time())
        window_start = now - (now % rate.window_seconds)
        reset = window_start + rate.window_seconds

        with self._lock:
            prev = self._buckets.get(key)
            if not prev or prev[0] != window_start:
                count = 1
            else:
                count = prev[1] + 1

            self._buckets[key] = (window_start, count)

        remaining = max(0, rate.limit - count)
        allowed = count <= rate.limit
        return allowed, remaining, reset


def _client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",", 1)[0].strip()
    if request.client and request.client.host:
        return request.client.host
    return "unknown"


def _rate_limit_key(request: Request) -> str:
    # Prefer explicit app_uuid when present in query/header to reduce cross-app coupling.
    app_uuid = request.headers.get("x-app-uuid") or request.query_params.get("app_uuid")
    ip = _client_ip(request)
    if app_uuid:
        return f"{app_uuid}:{ip}:{request.method}:{request.url.path}"
    return f"{ip}:{request.method}:{request.url.path}"


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Simple fixed-window rate limiting.

    Notes:
    - In-memory backend is best-effort (suitable for dev/single instance).
    - In production, prefer perimetral rate limiting (API Gateway/Apigee) or a shared backend.
    """

    def __init__(
        self,
        app,
        *,
        service: str,
        enabled: bool,
        rules: Iterable[Rule],
    ) -> None:
        super().__init__(app)
        self._service = service
        self._enabled = enabled
        self._rules = list(rules)
        self._limiter = _FixedWindowInMemory()

    async def dispatch(self, request: Request, call_next) -> Response:
        if not self._enabled:
            return await call_next(request)

        rule = next((r for r in self._rules if r.matches(request)), None)
        if rule is None:
            return await call_next(request)

        key = _rate_limit_key(request)
        allowed, remaining, reset = self._limiter.hit(key, rule.rate)

        if not allowed:
            try:
                from .metrics import inc_rate_limited

                inc_rate_limited(service=self._service, method=request.method, path=request.url.path)
            except Exception:
                pass
            resp = JSONResponse(
                status_code=429,
                content={"detail": "rate limit exceeded"},
            )
        else:
            resp = await call_next(request)

        resp.headers["X-RateLimit-Limit"] = str(rule.rate.limit)
        resp.headers["X-RateLimit-Remaining"] = str(remaining)
        resp.headers["X-RateLimit-Reset"] = str(reset)
        return resp
