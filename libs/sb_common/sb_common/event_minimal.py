from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

from .config import settings


class MinimalEventError(ValueError):
    pass


@dataclass(frozen=True)
class MinimalEvent:
    event_id: str
    trace_id: str
    producer: str
    actor: str
    app_uuid: str
    event_type: str
    timestamp: datetime
    anon_user_id: str
    device_id_hash: str
    session_id: str
    sdk_version: str
    event_version: str
    payload: dict[str, Any]
    context: dict[str, Any]


REQUIRED_FIELDS = (
    # Envelope (legacy names). Prompt Maestro equivalents are also supported.
    "app_uuid",
    "event_type",
    "timestamp",
    "anon_user_id",
    "device_id_hash",
    "session_id",
    "sdk_version",
    "event_version",
    "payload",
    "context",
)


def _coerce_uuid(v: Any) -> str:
    if isinstance(v, UUID):
        return str(v)
    if isinstance(v, str):
        # Validate formatting (raises ValueError if invalid)
        return str(UUID(v))
    raise ValueError("invalid uuid")


def _parse_ts(v: Any, *, field_name: str) -> datetime:
    if not isinstance(v, str):
        raise MinimalEventError(f"{field_name} must be ISO-8601 string")
    try:
        ts = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception as exc:  # noqa: BLE001
        raise MinimalEventError(f"invalid {field_name}") from exc
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts


def parse_minimal_event(doc: dict[str, Any]) -> MinimalEvent:
    # Backward compatibility:
    # - event_type <-> event_name
    # - timestamp <-> occurred_at
    # - optional trace_id/event_id/producer/actor
    if settings.strict_envelope:
        required_pm = ["event_name", "occurred_at", "event_id", "trace_id", "producer", "actor"]
        missing_pm = [k for k in required_pm if k not in doc or doc.get(k) in (None, "")]
        if missing_pm:
            raise MinimalEventError(f"missing required envelope fields: {missing_pm}")

        # Normalize to internal field names used downstream
        doc = {
            **doc,
            "event_type": doc.get("event_name"),
            "timestamp": doc.get("occurred_at"),
        }
    else:
        if "event_type" not in doc and "event_name" in doc:
            doc = {**doc, "event_type": doc.get("event_name")}
        if "timestamp" not in doc and "occurred_at" in doc:
            doc = {**doc, "timestamp": doc.get("occurred_at")}

    missing = [k for k in REQUIRED_FIELDS if k not in doc]
    if missing:
        raise MinimalEventError(f"missing required fields: {missing}")

    ts = _parse_ts(doc["timestamp"], field_name="timestamp")

    payload = doc.get("payload")
    if payload is None or not isinstance(payload, dict):
        raise MinimalEventError("payload must be object")

    context = doc.get("context")
    if context is None or not isinstance(context, dict):
        raise MinimalEventError("context must be object")

    # Envelope handling
    try:
        if settings.strict_envelope:
            event_id = _coerce_uuid(doc.get("event_id"))
            trace_id = _coerce_uuid(doc.get("trace_id"))
        else:
            event_id = _coerce_uuid(doc.get("event_id") or uuid4())
            trace_id = _coerce_uuid(doc.get("trace_id") or uuid4())
    except Exception as exc:
        raise MinimalEventError("invalid event_id/trace_id") from exc

    producer = doc.get("producer")
    actor = doc.get("actor")
    if settings.strict_envelope:
        if producer is None or str(producer).strip() == "":
            raise MinimalEventError("missing producer")
        if actor is None or str(actor).strip() == "":
            raise MinimalEventError("missing actor")
    else:
        if producer is None:
            producer = "smartbuket-sdk"
        if actor is None:
            actor = "anonymous"

    return MinimalEvent(
        event_id=event_id,
        trace_id=trace_id,
        producer=str(producer),
        actor=str(actor),
        app_uuid=str(doc["app_uuid"]),
        event_type=str(doc["event_type"]),
        timestamp=ts,
        anon_user_id=str(doc["anon_user_id"]),
        device_id_hash=str(doc["device_id_hash"]),
        session_id=str(doc["session_id"]),
        sdk_version=str(doc["sdk_version"]),
        event_version=str(doc["event_version"]),
        payload=payload,
        context=context,
    )
