from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


class MinimalEventError(ValueError):
    pass


@dataclass(frozen=True)
class MinimalEvent:
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


def parse_minimal_event(doc: dict[str, Any]) -> MinimalEvent:
    missing = [k for k in REQUIRED_FIELDS if k not in doc]
    if missing:
        raise MinimalEventError(f"missing required fields: {missing}")

    ts_raw = doc["timestamp"]
    if not isinstance(ts_raw, str):
        raise MinimalEventError("timestamp must be ISO-8601 string")

    try:
        ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
    except Exception as exc:  # noqa: BLE001
        raise MinimalEventError("invalid timestamp") from exc

    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)

    payload = doc.get("payload")
    if payload is None or not isinstance(payload, dict):
        raise MinimalEventError("payload must be object")

    context = doc.get("context")
    if context is None or not isinstance(context, dict):
        raise MinimalEventError("context must be object")

    return MinimalEvent(
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
