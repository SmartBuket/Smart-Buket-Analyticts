from __future__ import annotations

from datetime import datetime
from typing import Any

import orjson
from fastapi import Body, Depends, FastAPI, HTTPException
from sqlalchemy import text

from sb_common.auth import require_api_key, require_scopes
from sb_common.config import settings
from sb_common.db import get_engine
from sb_common.event_minimal import MinimalEventError, parse_minimal_event
from sb_common.hardening import setup_hardening
from sb_common.metrics import add_metrics
from sb_common.observability import setup_observability
from sb_common.privacy import is_opted_out
from sb_common.rate_limit import RateLimitMiddleware, Rule, parse_rate
from sb_common.schema import ensure_outbox, ensure_processed_events, ensure_raw_events_envelope


app = FastAPI(
    title="SmartBuket Analytics Ingest API",
    version="0.1.0",
    dependencies=[Depends(require_api_key)],
)

setup_observability(app, log_level=settings.log_level)
setup_hardening(app)

if settings.metrics_enabled:
    add_metrics(app, service="ingest-api", public=settings.metrics_public)

app.add_middleware(
    RateLimitMiddleware,
    service="ingest-api",
    enabled=settings.rate_limit_enabled,
    rules=[
        Rule("POST", "/v1/events", parse_rate(settings.rate_limit_ingest_events)),
        Rule("POST", "/v1/opt-out", parse_rate(settings.rate_limit_privacy)),
        Rule("POST", "/v1/privacy/delete", parse_rate(settings.rate_limit_privacy)),
    ],
)


@app.on_event("startup")
def _startup() -> None:
    engine = get_engine()
    ensure_raw_events_envelope(engine)
    ensure_outbox(engine)
    ensure_processed_events(engine)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post(
    "/v1/events",
    dependencies=[Depends(require_scopes("sb.ingest.write"))],
)
def ingest_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    if not isinstance(events, list) or not events:
        raise HTTPException(status_code=400, detail="body must be a non-empty list")

    engine = get_engine()

    accepted = 0
    deduped = 0
    rejected: list[dict[str, Any]] = []

    insert_sql = text(
                """
                INSERT INTO raw_events (
                    event_id, trace_id, producer, actor,
                    app_uuid, event_type, event_ts,
                    anon_user_id, device_id_hash, session_id,
                    sdk_version, event_version,
                    geo_point, geo_accuracy_m, geo_source,
                    payload, context, raw_doc
                )
                VALUES (
                    CAST(:event_id AS uuid), CAST(:trace_id AS uuid), :producer, :actor,
                    CAST(:app_uuid AS uuid), :event_type, :event_ts,
                    :anon_user_id, :device_id_hash, :session_id,
                    :sdk_version, :event_version,
                    CASE WHEN :lat IS NULL OR :lon IS NULL THEN NULL
                             ELSE ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) END,
                    :accuracy_m, :geo_source,
                    CAST(:payload AS jsonb), CAST(:context AS jsonb), CAST(:raw_doc AS jsonb)
                )
                ON CONFLICT (app_uuid, event_id) DO NOTHING
                """
        )

    outbox_sql = text(
                """
                INSERT INTO outbox_events (
                    app_uuid, event_id, trace_id, occurred_at,
                    routing_key, payload
                )
                VALUES (
                    CAST(:app_uuid AS uuid), CAST(:event_id AS uuid), CAST(:trace_id AS uuid), :occurred_at,
                    :routing_key, CAST(:payload AS jsonb)
                )
                ON CONFLICT (app_uuid, event_id, routing_key) DO NOTHING
                """
        )

    with engine.begin() as conn:
        opted_out_cache: set[tuple[str, str]] = set()
        for idx, doc in enumerate(events):
            try:
                ev = parse_minimal_event(doc)

                cache_key = (str(ev.app_uuid), str(ev.anon_user_id))
                if cache_key in opted_out_cache or is_opted_out(
                    conn,
                    app_uuid=str(ev.app_uuid),
                    anon_user_id=str(ev.anon_user_id),
                ):
                    opted_out_cache.add(cache_key)
                    rejected.append({"index": idx, "error": "opt_out"})
                    continue

                geo = (ev.context or {}).get("geo") or {}
                lat = geo.get("lat")
                lon = geo.get("lon")
                accuracy_m = geo.get("accuracy_m")
                geo_source = geo.get("source")

                ins_res = conn.execute(
                    insert_sql,
                    {
                        "event_id": ev.event_id,
                        "trace_id": ev.trace_id,
                        "producer": ev.producer,
                        "actor": ev.actor,
                        "app_uuid": ev.app_uuid,
                        "event_type": ev.event_type,
                        "event_ts": ev.timestamp.isoformat(),
                        "anon_user_id": ev.anon_user_id,
                        "device_id_hash": ev.device_id_hash,
                        "session_id": ev.session_id,
                        "sdk_version": ev.sdk_version,
                        "event_version": ev.event_version,
                        "lat": lat if isinstance(lat, (int, float)) else None,
                        "lon": lon if isinstance(lon, (int, float)) else None,
                        "accuracy_m": float(accuracy_m) if isinstance(accuracy_m, (int, float)) else None,
                        "geo_source": str(geo_source) if geo_source is not None else None,
                        "payload": orjson.dumps(ev.payload).decode("utf-8"),
                        "context": orjson.dumps(ev.context).decode("utf-8"),
                        "raw_doc": orjson.dumps(doc).decode("utf-8"),
                    },
                )

                # Idempotency: if this event_id was already ingested for this app_uuid,
                # skip staging outbox fan-out to avoid re-processing.
                if getattr(ins_res, "rowcount", 1) == 0:
                    deduped += 1
                    continue

                # Outbox Pattern: stage broker publishing inside the DB transaction.
                # One event can fan out to multiple routing keys.
                staged_payload = {
                    **doc,
                    # Ensure Prompt Maestro envelope keys exist (backward compatible)
                    "event_id": ev.event_id,
                    "trace_id": ev.trace_id,
                    "producer": ev.producer,
                    "actor": ev.actor,
                    "occurred_at": ev.timestamp.isoformat().replace("+00:00", "Z"),
                    "event_name": ev.event_type,
                }

                routing_keys = [settings.topic_raw]
                if ev.event_type == "geo.ping":
                    routing_keys.append(settings.topic_geo)
                if ev.event_type.startswith("license."):
                    routing_keys.append(settings.topic_license)
                if ev.event_type.startswith("session."):
                    routing_keys.append(settings.topic_session)
                if ev.event_type.startswith("screen."):
                    routing_keys.append(settings.topic_screen)
                if ev.event_type.startswith("ui."):
                    routing_keys.append(settings.topic_ui)
                if ev.event_type.startswith("system."):
                    routing_keys.append(settings.topic_system)

                for rk in routing_keys:
                    conn.execute(
                        outbox_sql,
                        {
                            "app_uuid": ev.app_uuid,
                            "event_id": ev.event_id,
                            "trace_id": ev.trace_id,
                            "occurred_at": ev.timestamp,
                            "routing_key": rk,
                            "payload": orjson.dumps(staged_payload).decode("utf-8"),
                        },
                    )

                accepted += 1
            except MinimalEventError as exc:
                rejected.append({"index": idx, "error": str(exc)})

    return {"accepted": accepted, "deduped": deduped, "rejected": rejected}


@app.post(
    "/v1/opt-out",
    dependencies=[Depends(require_scopes("sb.privacy.write"))],
)
def opt_out(body: dict[str, Any]) -> dict[str, str]:
    # Opt-out is recorded per app + anon_user_id. No PII.
    app_uuid = body.get("app_uuid")
    anon_user_id = body.get("anon_user_id")
    if not app_uuid or not anon_user_id:
        raise HTTPException(status_code=400, detail="app_uuid and anon_user_id are required")

    sql = text(
        """
        INSERT INTO opt_out (app_uuid, anon_user_id)
        VALUES (CAST(:app_uuid AS uuid), :anon_user_id)
        ON CONFLICT (app_uuid, anon_user_id) DO NOTHING
        """
    )

    with get_engine().begin() as conn:
        conn.execute(sql, {"app_uuid": str(app_uuid), "anon_user_id": str(anon_user_id)})

    return {"status": "ok"}


@app.post(
    "/v1/privacy/delete",
    dependencies=[Depends(require_scopes("sb.privacy.delete"))],
)
def privacy_delete_user(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
    """Delete all stored data for a user within an app.

    This does NOT delete already-published Kafka messages; it deletes DB state only.
    """

    app_uuid = body.get("app_uuid")
    anon_user_id = body.get("anon_user_id")
    delete_opt_out = bool(body.get("delete_opt_out", False))

    if not app_uuid or not anon_user_id:
        raise HTTPException(status_code=400, detail="app_uuid and anon_user_id are required")

    params = {"app_uuid": str(app_uuid), "anon_user_id": str(anon_user_id)}

    statements: list[tuple[str, Any]] = [
        (
            "customer_360",
            text(
                """
                DELETE FROM customer_360
                WHERE app_uuid = CAST(:app_uuid AS uuid)
                  AND anon_user_id = :anon_user_id
                """
            ),
        ),
        (
            "license_state",
            text(
                """
                DELETE FROM license_state
                WHERE app_uuid = CAST(:app_uuid AS uuid)
                  AND anon_user_id = :anon_user_id
                """
            ),
        ),
        (
            "user_hourly_presence",
            text(
                """
                DELETE FROM user_hourly_presence
                WHERE app_uuid = CAST(:app_uuid AS uuid)
                  AND anon_user_id = :anon_user_id
                """
            ),
        ),
        (
            "device_hourly_presence",
            text(
                """
                DELETE FROM device_hourly_presence
                WHERE app_uuid = CAST(:app_uuid AS uuid)
                  AND anon_user_id = :anon_user_id
                """
            ),
        ),
        (
            "raw_events",
            text(
                """
                DELETE FROM raw_events
                WHERE app_uuid = CAST(:app_uuid AS uuid)
                  AND anon_user_id = :anon_user_id
                """
            ),
        ),
    ]

    if delete_opt_out:
        statements.append(
            (
                "opt_out",
                text(
                    """
                    DELETE FROM opt_out
                    WHERE app_uuid = CAST(:app_uuid AS uuid)
                      AND anon_user_id = :anon_user_id
                    """
                ),
            )
        )

    deleted: dict[str, int] = {}
    with get_engine().begin() as conn:
        for table_name, stmt in statements:
            res = conn.execute(stmt, params)
            deleted[table_name] = int(res.rowcount or 0)

    return {
        "status": "ok",
        "app_uuid": str(app_uuid),
        "anon_user_id": str(anon_user_id),
        "deleted": deleted,
        "notes": {
            "kafka": "Kafka topics are append-only; historical messages are not deleted.",
            "opt_out": "Set delete_opt_out=true to remove opt_out row; default keeps it.",
        },
    }
