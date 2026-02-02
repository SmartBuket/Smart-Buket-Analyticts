from __future__ import annotations

import contextvars
import json
import logging
import sys
import time
import uuid
from typing import Any, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


_trace_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar("sb_trace_id", default=None)


def get_trace_id() -> str | None:
    return _trace_id_var.get()


class _TraceIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        trace_id = get_trace_id()
        setattr(record, "trace_id", trace_id)
        return True


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        trace_id = getattr(record, "trace_id", None)
        if trace_id:
            payload["trace_id"] = trace_id

        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)

        return json.dumps(payload, ensure_ascii=False)


def configure_json_logging(level: str = "INFO") -> None:
    """Configure process-wide JSON logging.

    This is idempotent and safe to call multiple times.
    """

    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    # Avoid duplicating handlers if called multiple times.
    for h in list(root.handlers):
        if getattr(h, "_sb_json_logging", False):
            return

    handler = logging.StreamHandler(sys.stdout)
    handler._sb_json_logging = True  # type: ignore[attr-defined]
    handler.setFormatter(_JsonFormatter())
    handler.addFilter(_TraceIdFilter())

    root.addHandler(handler)


def _pick_incoming_trace_id(request: Request) -> str | None:
    for header in ("x-trace-id", "x-request-id"):
        val = request.headers.get(header)
        if val and val.strip():
            return val.strip()
    return None


class TraceIdMiddleware(BaseHTTPMiddleware):
    """Attach a trace id to each request.

    - Reads `X-Trace-Id`/`X-Request-Id` if present.
    - Otherwise generates a UUID4.
    - Exposes `request.state.trace_id` and sets response header `X-Trace-Id`.
    """

    def __init__(self, app, header_name: str = "X-Trace-Id"):
        super().__init__(app)
        self._header_name = header_name

    async def dispatch(self, request: Request, call_next: Callable[[Request], Any]) -> Response:
        incoming = _pick_incoming_trace_id(request)
        trace_id = incoming or str(uuid.uuid4())

        token = _trace_id_var.set(trace_id)
        request.state.trace_id = trace_id
        try:
            response = await call_next(request)
        finally:
            _trace_id_var.reset(token)

        response.headers[self._header_name] = trace_id
        return response


def setup_observability(app, *, log_level: str = "INFO") -> None:
    configure_json_logging(level=log_level)
    app.add_middleware(TraceIdMiddleware)
