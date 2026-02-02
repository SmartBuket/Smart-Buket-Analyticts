from __future__ import annotations

import time
from typing import Any, Callable

from fastapi import FastAPI
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


HTTP_REQUESTS_TOTAL = Counter(
    "sb_http_requests_total",
    "Total HTTP requests",
    ["service", "method", "path", "status"],
)

HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "sb_http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["service", "method", "path"],
)

RATE_LIMITED_TOTAL = Counter(
    "sb_rate_limited_total",
    "Total requests blocked by in-app rate limiting",
    ["service", "method", "path"],
)


def _route_path_template(request: Request) -> str:
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    if isinstance(path, str) and path:
        return path
    return request.url.path


class MetricsMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, *, service: str) -> None:
        super().__init__(app)
        self._service = service

    async def dispatch(self, request: Request, call_next: Callable[[Request], Any]) -> Response:
        method = request.method.upper()
        path = _route_path_template(request)

        start = time.perf_counter()
        status = "500"
        try:
            response = await call_next(request)
            status = str(response.status_code)
            return response
        finally:
            elapsed = time.perf_counter() - start
            HTTP_REQUEST_DURATION_SECONDS.labels(self._service, method, path).observe(elapsed)
            HTTP_REQUESTS_TOTAL.labels(self._service, method, path, status).inc()


def inc_rate_limited(*, service: str, method: str, path: str) -> None:
    RATE_LIMITED_TOTAL.labels(service, method.upper(), path).inc()


def add_metrics(app: FastAPI, *, service: str, public: bool = False) -> None:
    """Expose Prometheus metrics.

    If `public=True`, mounts a separate sub-app at `/metrics` which bypasses the
    parent's global dependencies (useful when main API is protected).
    """

    app.add_middleware(MetricsMiddleware, service=service)

    async def _metrics() -> Response:
        data = generate_latest()
        return Response(content=data, media_type=CONTENT_TYPE_LATEST)

    if public:
        metrics_app = FastAPI(title=f"{service} metrics")
        metrics_app.add_api_route("/", _metrics, methods=["GET"], include_in_schema=False)
        app.mount("/metrics", metrics_app)
    else:
        app.add_api_route("/metrics", _metrics, methods=["GET"], include_in_schema=False)
