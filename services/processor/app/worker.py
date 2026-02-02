from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import base64
import threading
import time
import traceback
from typing import Any

import orjson
import h3
import pika
from shapely.geometry import Polygon
from sqlalchemy import text
from sqlalchemy.engine import Connection
from sqlalchemy.exc import DBAPIError, OperationalError

from sb_common.config import settings
from sb_common.db import get_engine
from sb_common.event_minimal import MinimalEventError, parse_minimal_event
from sb_common.privacy import is_opted_out
from sb_common.schema import ensure_aggregates, ensure_customer_360, ensure_processed_events


MARK_PROCESSED_SQL = text(
    """
    INSERT INTO processed_events (consumer, app_uuid, event_id)
    VALUES (:consumer, CAST(:app_uuid AS uuid), CAST(:event_id AS uuid))
    ON CONFLICT (consumer, app_uuid, event_id) DO NOTHING
    RETURNING 1
    """
)


@dataclass(frozen=True)
class GeoDims:
    lat: float
    lon: float
    accuracy_m: float | None
    h3_r7: str | None
    h3_r9: str | None
    h3_r11: str | None
    place_id: str | None
    precision_class: str
    admin_country_code: str | None
    admin_province_code: str | None
    admin_municipality_code: str | None
    admin_sector_code: str | None


def floor_to_hour(ts: datetime) -> datetime:
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)


def classify_precision(accuracy_m: float | None) -> str:
    if accuracy_m is None:
        return "unknown"
    if accuracy_m <= 50:
        return "fine"
    if accuracy_m <= 500:
        return "medium"
    return "coarse"


def compute_geo_dims(context: dict[str, Any]) -> GeoDims | None:
    geo = (context or {}).get("geo") or {}
    lat = geo.get("lat")
    lon = geo.get("lon")
    if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
        return None

    accuracy_m = geo.get("accuracy_m")
    acc = float(accuracy_m) if isinstance(accuracy_m, (int, float)) else None

    precision_class = classify_precision(acc)

    # H3 always computed; consumers can degrade to macro by filtering precision_class.
    # h3-py v4 API: latlng_to_cell(lat, lng, res)
    h3_r7 = h3.latlng_to_cell(lat, lon, 7)
    h3_r9 = h3.latlng_to_cell(lat, lon, 9)
    h3_r11 = h3.latlng_to_cell(lat, lon, 11)

    return GeoDims(
        lat=float(lat),
        lon=float(lon),
        accuracy_m=acc,
        h3_r7=h3_r7,
        h3_r9=h3_r9,
        h3_r11=h3_r11,
        place_id=None,
        precision_class=precision_class,
        admin_country_code=None,
        admin_province_code=None,
        admin_municipality_code=None,
        admin_sector_code=None,
    )


_h3_cells_lock = threading.Lock()
_h3_cells_seen: set[str] = set()


def _ensure_h3_cell(conn: Connection, h3_cell: str) -> None:
    # Avoid repeated DB writes in a hot loop.
    with _h3_cells_lock:
        if h3_cell in _h3_cells_seen:
            return
        # Soft cap to avoid unbounded growth in long-running dev.
        if len(_h3_cells_seen) > 20000:
            _h3_cells_seen.clear()
        _h3_cells_seen.add(h3_cell)

    res = h3.get_resolution(h3_cell)
    lat, lon = h3.cell_to_latlng(h3_cell)
    boundary = h3.cell_to_boundary(h3_cell)

    # h3 returns (lat, lon); shapely expects (x=lon, y=lat)
    ring = [(float(p[1]), float(p[0])) for p in boundary]
    if ring and ring[0] != ring[-1]:
        ring.append(ring[0])

    poly = Polygon(ring)
    wkt = poly.wkt

    sql = text(
        """
        INSERT INTO h3_cells (h3_cell, resolution, geom, centroid, centroid_lat, centroid_lon)
        VALUES (
            :h3_cell,
            :resolution,
            ST_SetSRID(ST_GeomFromText(:geom_wkt), 4326),
            ST_SetSRID(ST_MakePoint(:centroid_lon, :centroid_lat), 4326),
            :centroid_lat,
            :centroid_lon
        )
        ON CONFLICT (h3_cell) DO NOTHING
        """
    )

    conn.execute(
        sql,
        {
            "h3_cell": h3_cell,
            "resolution": int(res),
            "geom_wkt": wkt,
            "centroid_lat": float(lat),
            "centroid_lon": float(lon),
        },
    )


def lookup_admin_codes(conn: Connection, lat: float, lon: float, event_ts: datetime) -> dict[str, str | None]:
    sql = text(
        """
        WITH p AS (
          SELECT ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) AS geom
        )
        SELECT level, code
        FROM admin_areas a, p
        WHERE ST_Contains(a.geom, p.geom)
          AND (a.valid_from IS NULL OR a.valid_from <= :ts)
          AND (a.valid_to IS NULL OR a.valid_to >= :ts)
        """
    )

    out: dict[str, str | None] = {
        "country": None,
        "province": None,
        "municipality": None,
        "sector": None,
    }

    rows = conn.execute(sql, {"lat": lat, "lon": lon, "ts": event_ts}).mappings().all()
    for r in rows:
        lvl = str(r["level"])
        if lvl in out and out[lvl] is None:
            out[lvl] = str(r["code"])

    return out


def lookup_place_id(conn: Connection, lat: float, lon: float, event_ts: datetime) -> str | None:
    # MVP: simple PostGIS contains check. For scale: pre-index by bbox / H3 and batch.
    sql = text(
        """
        SELECT place_id
        FROM places
        WHERE ST_Contains(geofence, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))
          AND (valid_from IS NULL OR valid_from <= :ts)
          AND (valid_to IS NULL OR valid_to >= :ts)
        LIMIT 1
        """
    )

    row = conn.execute(sql, {"lat": lat, "lon": lon, "ts": event_ts}).first()
    return row[0] if row else None


def upsert_customer_360_from_geo(
    conn: Connection,
    parsed: Any,
    *,
    h3_r9: str | None,
    place_id: str | None,
    admin_country_code: str | None,
    admin_province_code: str | None,
    admin_municipality_code: str | None,
    admin_sector_code: str | None,
) -> None:
        sql = text(
                """
                INSERT INTO customer_360 (
                    app_uuid, anon_user_id, device_id_hash,
                    first_seen_at, last_seen_at,
                    last_event_type, last_session_id, last_sdk_version, last_event_version,
                    last_h3_r9, last_place_id,
                    last_admin_country_code, last_admin_province_code, last_admin_municipality_code, last_admin_sector_code,
                    geo_events_count, active_user_hours_count, active_device_hours_count,
                    updated_at
                )
                VALUES (
                    CAST(:app_uuid AS uuid), :anon_user_id, :device_id_hash,
                    :event_ts, :event_ts,
                    :event_type, :session_id, :sdk_version, :event_version,
                    :h3_r9, :place_id,
                    :admin_country_code, :admin_province_code, :admin_municipality_code, :admin_sector_code,
                                        1,
                                        (
                                            SELECT COUNT(*)
                                            FROM user_hourly_presence
                                            WHERE app_uuid = CAST(:app_uuid AS uuid)
                                                AND anon_user_id = :anon_user_id
                                        ),
                                        (
                                            SELECT COUNT(*)
                                            FROM device_hourly_presence
                                            WHERE app_uuid = CAST(:app_uuid AS uuid)
                                                AND device_id_hash = :device_id_hash
                                        ),
                    now()
                )
                ON CONFLICT (app_uuid, anon_user_id)
                DO UPDATE SET
                    device_id_hash = EXCLUDED.device_id_hash,
                    first_seen_at = LEAST(customer_360.first_seen_at, EXCLUDED.first_seen_at),
                    last_seen_at = GREATEST(customer_360.last_seen_at, EXCLUDED.last_seen_at),
                    last_event_type = EXCLUDED.last_event_type,
                    last_session_id = EXCLUDED.last_session_id,
                    last_sdk_version = EXCLUDED.last_sdk_version,
                    last_event_version = EXCLUDED.last_event_version,
                    last_h3_r9 = EXCLUDED.last_h3_r9,
                    last_place_id = EXCLUDED.last_place_id,
                    last_admin_country_code = EXCLUDED.last_admin_country_code,
                    last_admin_province_code = EXCLUDED.last_admin_province_code,
                    last_admin_municipality_code = EXCLUDED.last_admin_municipality_code,
                    last_admin_sector_code = EXCLUDED.last_admin_sector_code,
                    geo_events_count = customer_360.geo_events_count + 1,
                                        active_user_hours_count = (
                                            SELECT COUNT(*)
                                            FROM user_hourly_presence
                                            WHERE app_uuid = customer_360.app_uuid
                                                AND anon_user_id = customer_360.anon_user_id
                                        ),
                                        active_device_hours_count = (
                                            SELECT COUNT(*)
                                            FROM device_hourly_presence
                                            WHERE app_uuid = customer_360.app_uuid
                                                AND device_id_hash = EXCLUDED.device_id_hash
                                        ),
                    updated_at = now()
                """
        )

        params = {
                "app_uuid": parsed.app_uuid,
                "anon_user_id": parsed.anon_user_id,
                "device_id_hash": parsed.device_id_hash,
                "event_ts": parsed.timestamp,
                "event_type": parsed.event_type,
                "session_id": parsed.session_id,
                "sdk_version": parsed.sdk_version,
                "event_version": parsed.event_version,
                "h3_r9": h3_r9,
                "place_id": place_id,
                "admin_country_code": admin_country_code,
                "admin_province_code": admin_province_code,
                "admin_municipality_code": admin_municipality_code,
                "admin_sector_code": admin_sector_code,
        }

        conn.execute(sql, params)


def upsert_presence(conn: Connection, ev: dict[str, Any]) -> None:
    parsed = parse_minimal_event(ev)

    dims = compute_geo_dims(parsed.context)
    if dims is None:
        return

    if dims.h3_r7:
        _ensure_h3_cell(conn, dims.h3_r7)
    if dims.h3_r9:
        _ensure_h3_cell(conn, dims.h3_r9)
    if dims.h3_r11:
        _ensure_h3_cell(conn, dims.h3_r11)

    place_id = lookup_place_id(conn, dims.lat, dims.lon, parsed.timestamp)

    # Admin zoning: degrade to macro levels if precision is coarse.
    admin = lookup_admin_codes(conn, dims.lat, dims.lon, parsed.timestamp)
    country = admin["country"]
    province = admin["province"]
    municipality = admin["municipality"]
    sector = admin["sector"]

    if dims.precision_class == "coarse":
        municipality = None
        sector = None

    hour_bucket = floor_to_hour(parsed.timestamp)

    insert_device = text(
        """
        INSERT INTO device_hourly_presence (
          app_uuid, hour_bucket, device_id_hash, anon_user_id,
          h3_r7, h3_r9, h3_r11, place_id,
          admin_country_code, admin_province_code, admin_municipality_code, admin_sector_code,
          geo_accuracy_m, geo_precision_class, first_event_ts
        )
        VALUES (
          CAST(:app_uuid AS uuid), :hour_bucket, :device_id_hash, :anon_user_id,
          :h3_r7, :h3_r9, :h3_r11, :place_id,
          :admin_country_code, :admin_province_code, :admin_municipality_code, :admin_sector_code,
          :geo_accuracy_m, :geo_precision_class, :first_event_ts
        )
        ON CONFLICT (app_uuid, hour_bucket, device_id_hash) DO NOTHING
        RETURNING 1
        """
    )

    insert_user = text(
        """
        INSERT INTO user_hourly_presence (
          app_uuid, hour_bucket, anon_user_id,
          h3_r7, h3_r9, h3_r11, place_id,
          admin_country_code, admin_province_code, admin_municipality_code, admin_sector_code,
          geo_accuracy_m, geo_precision_class, first_event_ts
        )
        VALUES (
          CAST(:app_uuid AS uuid), :hour_bucket, :anon_user_id,
          :h3_r7, :h3_r9, :h3_r11, :place_id,
          :admin_country_code, :admin_province_code, :admin_municipality_code, :admin_sector_code,
          :geo_accuracy_m, :geo_precision_class, :first_event_ts
        )
        ON CONFLICT (app_uuid, hour_bucket, anon_user_id) DO NOTHING
        RETURNING 1
        """
    )

    upsert_h3 = text(
        """
        INSERT INTO agg_h3_r9_hourly (app_uuid, hour_bucket, h3_r9, devices_count, users_count, updated_at)
        VALUES (CAST(:app_uuid AS uuid), :hour_bucket, :h3_r9, :devices_inc, :users_inc, now())
        ON CONFLICT (app_uuid, hour_bucket, h3_r9)
        DO UPDATE SET
          devices_count = agg_h3_r9_hourly.devices_count + EXCLUDED.devices_count,
          users_count = agg_h3_r9_hourly.users_count + EXCLUDED.users_count,
          updated_at = now()
        """
    )

    upsert_place = text(
        """
        INSERT INTO agg_place_hourly (app_uuid, hour_bucket, place_id, devices_count, users_count, updated_at)
        VALUES (CAST(:app_uuid AS uuid), :hour_bucket, :place_id, :devices_inc, :users_inc, now())
        ON CONFLICT (app_uuid, hour_bucket, place_id)
        DO UPDATE SET
          devices_count = agg_place_hourly.devices_count + EXCLUDED.devices_count,
          users_count = agg_place_hourly.users_count + EXCLUDED.users_count,
          updated_at = now()
        """
    )

    upsert_admin = text(
        """
        INSERT INTO agg_admin_hourly (app_uuid, hour_bucket, level, code, devices_count, users_count, updated_at)
        VALUES (CAST(:app_uuid AS uuid), :hour_bucket, :level, :code, :devices_inc, :users_inc, now())
        ON CONFLICT (app_uuid, hour_bucket, level, code)
        DO UPDATE SET
          devices_count = agg_admin_hourly.devices_count + EXCLUDED.devices_count,
          users_count = agg_admin_hourly.users_count + EXCLUDED.users_count,
          updated_at = now()
        """
    )

    params = {
        "app_uuid": parsed.app_uuid,
        "hour_bucket": hour_bucket,
        "device_id_hash": parsed.device_id_hash,
        "anon_user_id": parsed.anon_user_id,
        "h3_r7": dims.h3_r7,
        "h3_r9": dims.h3_r9,
        "h3_r11": dims.h3_r11,
        "place_id": place_id,
        "admin_country_code": country,
        "admin_province_code": province,
        "admin_municipality_code": municipality,
        "admin_sector_code": sector,
        "geo_accuracy_m": dims.accuracy_m,
        "geo_precision_class": dims.precision_class,
        "first_event_ts": parsed.timestamp,
    }

    def _apply_admin_incs(conn: Any, *, devices_inc: int, users_inc: int) -> None:
        if devices_inc == 0 and users_inc == 0:
            return
        for level, code in (
            ("country", country),
            ("province", province),
            ("municipality", municipality),
            ("sector", sector),
        ):
            if code is None:
                continue
            conn.execute(
                upsert_admin,
                {
                    "app_uuid": parsed.app_uuid,
                    "hour_bucket": hour_bucket,
                    "level": level,
                    "code": code,
                    "devices_inc": devices_inc,
                    "users_inc": users_inc,
                },
            )

    device_inserted = conn.execute(insert_device, params).first() is not None
    user_inserted = conn.execute(insert_user, params).first() is not None

    devices_inc = 1 if device_inserted else 0
    users_inc = 1 if user_inserted else 0

    if (devices_inc or users_inc) and dims.h3_r9 is not None:
        conn.execute(
            upsert_h3,
            {
                "app_uuid": parsed.app_uuid,
                "hour_bucket": hour_bucket,
                "h3_r9": dims.h3_r9,
                "devices_inc": devices_inc,
                "users_inc": users_inc,
            },
        )

    if (devices_inc or users_inc) and place_id is not None:
        conn.execute(
            upsert_place,
            {
                "app_uuid": parsed.app_uuid,
                "hour_bucket": hour_bucket,
                "place_id": place_id,
                "devices_inc": devices_inc,
                "users_inc": users_inc,
            },
        )

    _apply_admin_incs(conn, devices_inc=devices_inc, users_inc=users_inc)

    upsert_customer_360_from_geo(
        conn,
        parsed,
        h3_r9=dims.h3_r9,
        place_id=place_id,
        admin_country_code=country,
        admin_province_code=province,
        admin_municipality_code=municipality,
        admin_sector_code=sector,
    )


def upsert_customer_360_from_license(
    conn: Connection,
    parsed: Any,
    *,
    plan_type: str,
    license_status: str,
    started_at: datetime | None,
    renewed_at: datetime | None,
    expires_at: datetime | None,
) -> None:
    sql = text(
        """
        INSERT INTO customer_360 (
          app_uuid, anon_user_id, device_id_hash,
          first_seen_at, last_seen_at,
          last_event_type, last_session_id, last_sdk_version, last_event_version,
          license_events_count,
          last_plan_type, last_license_status,
          license_started_at, license_renewed_at, license_expires_at,
          updated_at
        )
        VALUES (
          CAST(:app_uuid AS uuid), :anon_user_id, :device_id_hash,
          :event_ts, :event_ts,
          :event_type, :session_id, :sdk_version, :event_version,
          1,
          :plan_type, :license_status,
          :started_at, :renewed_at, :expires_at,
          now()
        )
        ON CONFLICT (app_uuid, anon_user_id)
        DO UPDATE SET
          device_id_hash = EXCLUDED.device_id_hash,
          first_seen_at = LEAST(customer_360.first_seen_at, EXCLUDED.first_seen_at),
          last_seen_at = GREATEST(customer_360.last_seen_at, EXCLUDED.last_seen_at),
          last_event_type = EXCLUDED.last_event_type,
          last_session_id = EXCLUDED.last_session_id,
          last_sdk_version = EXCLUDED.last_sdk_version,
          last_event_version = EXCLUDED.last_event_version,
          license_events_count = customer_360.license_events_count + 1,
          last_plan_type = EXCLUDED.last_plan_type,
          last_license_status = EXCLUDED.last_license_status,
          license_started_at = EXCLUDED.license_started_at,
          license_renewed_at = EXCLUDED.license_renewed_at,
          license_expires_at = EXCLUDED.license_expires_at,
          updated_at = now()
        """
    )

    conn.execute(
        sql,
        {
            "app_uuid": parsed.app_uuid,
            "anon_user_id": parsed.anon_user_id,
            "device_id_hash": parsed.device_id_hash,
            "event_ts": parsed.timestamp,
            "event_type": parsed.event_type,
            "session_id": parsed.session_id,
            "sdk_version": parsed.sdk_version,
            "event_version": parsed.event_version,
            "plan_type": plan_type,
            "license_status": license_status,
            "started_at": started_at,
            "renewed_at": renewed_at,
            "expires_at": expires_at,
        },
    )


def upsert_license(conn: Connection, ev: dict[str, Any]) -> None:
    parsed = parse_minimal_event(ev)

    # License updates are schema-light; recommended payload keys.
    payload = parsed.payload or {}
    plan_type = str(payload.get("plan_type", "unknown"))
    status = str(payload.get("license_status", "unknown"))

    started_at = payload.get("started_at")
    renewed_at = payload.get("renewed_at")
    expires_at = payload.get("expires_at")

    sql = text(
        """
        INSERT INTO license_state (
          app_uuid, anon_user_id, device_id_hash,
          plan_type, license_status,
          started_at, renewed_at, expires_at,
          updated_at
        )
        VALUES (
                    CAST(:app_uuid AS uuid), :anon_user_id, :device_id_hash,
          :plan_type, :license_status,
          :started_at, :renewed_at, :expires_at,
          now()
        )
        ON CONFLICT (app_uuid, anon_user_id)
        DO UPDATE SET
          device_id_hash = EXCLUDED.device_id_hash,
          plan_type = EXCLUDED.plan_type,
          license_status = EXCLUDED.license_status,
          started_at = EXCLUDED.started_at,
          renewed_at = EXCLUDED.renewed_at,
          expires_at = EXCLUDED.expires_at,
          updated_at = now()
        """
    )

    def _maybe_ts(v: Any) -> Any:
        if isinstance(v, str):
            try:
                return datetime.fromisoformat(v.replace("Z", "+00:00"))
            except Exception:
                return None
        return None

    params = {
        "app_uuid": parsed.app_uuid,
        "anon_user_id": parsed.anon_user_id,
        "device_id_hash": parsed.device_id_hash,
        "plan_type": plan_type,
        "license_status": status,
        "started_at": _maybe_ts(started_at),
        "renewed_at": _maybe_ts(renewed_at),
        "expires_at": _maybe_ts(expires_at),
    }

    conn.execute(sql, params)

    upsert_customer_360_from_license(
        conn,
        parsed,
        plan_type=plan_type,
        license_status=status,
        started_at=params["started_at"],
        renewed_at=params["renewed_at"],
        expires_at=params["expires_at"],
    )


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def publish_dlq(
    channel: pika.adapters.blocking_connection.BlockingChannel,
    delivery: Any,
    *,
    reason: str,
    error: Exception | None = None,
    decoded_doc: dict[str, Any] | None = None,
) -> None:
    value_b = delivery if delivery is not None else None
    value_b64 = (
        base64.b64encode(value_b).decode("ascii")
        if isinstance(value_b, (bytes, bytearray))
        else None
    )

    dlq_doc: dict[str, Any] = {
        "failed_at": _utc_now_iso(),
        "reason": reason,
        "source": {"broker": "rabbitmq"},
        "payload": {
            "raw_value_b64": value_b64,
            "decoded": decoded_doc,
        },
    }

    if error is not None:
        dlq_doc["error"] = {
            "type": type(error).__name__,
            "message": str(error),
        }

    try:
        props = pika.BasicProperties(content_type="application/json", delivery_mode=2)
        channel.basic_publish(
            exchange=settings.rabbitmq_exchange,
            routing_key=settings.topic_dlq,
            body=orjson.dumps(dlq_doc),
            properties=props,
        )
    except Exception:
        # DLQ must never take down the worker.
        print("processor: failed to publish DLQ message")
        traceback.print_exc()


def make_message_handler(
    *,
    engine: Any,
    channel: pika.adapters.blocking_connection.BlockingChannel,
    consumer_id: str,
    opted_out_cache: set[tuple[str, str]],
):
    """Build RabbitMQ on_message callback (test hook).

    Exposing this makes it possible to unit-test dedupe/ack behavior without
    running RabbitMQ or Postgres.
    """

    def _retry_delay_seconds(attempt: int) -> float:
        return min(settings.processor_retry_max_seconds, settings.processor_retry_base_seconds * (2**attempt))

    def _is_transient(exc: Exception) -> bool:
        if isinstance(exc, (OperationalError, DBAPIError)):
            return True
        if isinstance(exc, (TimeoutError, ConnectionError)):
            return True
        return False

    def _get_retry_count(props: Any) -> int:
        headers = getattr(props, "headers", None) or {}
        try:
            v = headers.get("sb_retry")
            return int(v) if v is not None else 0
        except Exception:
            return 0

    def _republish_with_retry(
        *,
        routing_key: str,
        body: bytes,
        props: Any,
        retry_count: int,
    ) -> None:
        headers = dict(getattr(props, "headers", None) or {})
        headers["sb_retry"] = retry_count
        headers["sb_retry_at"] = _utc_now_iso()

        new_props = pika.BasicProperties(
            content_type=getattr(props, "content_type", "application/json") or "application/json",
            delivery_mode=2,
            headers=headers,
        )
        channel.basic_publish(
            exchange=settings.rabbitmq_exchange,
            routing_key=routing_key,
            body=body,
            properties=new_props,
        )

    def _handle_message(_ch: Any, method: Any, props: Any, body: bytes) -> None:
        try:
            try:
                doc = orjson.loads(body)
            except Exception as exc:
                publish_dlq(channel, body, reason="json_decode", error=exc)
                _ch.basic_ack(delivery_tag=method.delivery_tag)
                return

            if not isinstance(doc, dict):
                publish_dlq(
                    channel,
                    body,
                    reason="invalid_document_type",
                    error=TypeError(f"expected object, got {type(doc).__name__}"),
                )
                _ch.basic_ack(delivery_tag=method.delivery_tag)
                return

            event_type = str(doc.get("event_type") or doc.get("event_name") or "")

            already_processed = False
            skip_processing = False

            with engine.begin() as c:
                app_uuid_for_dedupe = doc.get("app_uuid")
                event_id_for_dedupe = doc.get("event_id")
                if app_uuid_for_dedupe and event_id_for_dedupe:
                    res = c.execute(
                        MARK_PROCESSED_SQL,
                        {
                            "consumer": consumer_id,
                            "app_uuid": str(app_uuid_for_dedupe),
                            "event_id": str(event_id_for_dedupe),
                        },
                    ).first()
                    if res is None:
                        already_processed = True

                if not already_processed:
                    app_uuid = doc.get("app_uuid")
                    anon_user_id = doc.get("anon_user_id")
                    if app_uuid and anon_user_id:
                        cache_key = (str(app_uuid), str(anon_user_id))
                        if cache_key in opted_out_cache:
                            skip_processing = True
                        elif is_opted_out(c, app_uuid=str(app_uuid), anon_user_id=str(anon_user_id)):
                            opted_out_cache.add(cache_key)
                            skip_processing = True

                    if not skip_processing:
                        if method.routing_key == settings.topic_license or event_type.startswith("license."):
                            upsert_license(c, doc)
                        else:
                            if event_type == "geo.ping":
                                upsert_presence(c, doc)

            _ch.basic_ack(delivery_tag=method.delivery_tag)

        except MinimalEventError as exc:
            publish_dlq(channel, body, reason="minimal_event", error=exc, decoded_doc=doc if isinstance(doc, dict) else None)
            _ch.basic_ack(delivery_tag=method.delivery_tag)
        except Exception as exc:
            retry = _get_retry_count(props)
            if _is_transient(exc) and retry < settings.processor_max_retries:
                delay = _retry_delay_seconds(retry)
                print(
                    f"processor: transient error (retry {retry+1}/{settings.processor_max_retries}) after {delay:.2f}s: {exc}"
                )
                traceback.print_exc()
                time.sleep(delay)
                try:
                    _republish_with_retry(
                        routing_key=method.routing_key,
                        body=body,
                        props=props,
                        retry_count=retry + 1,
                    )
                    _ch.basic_ack(delivery_tag=method.delivery_tag)
                    return
                except Exception as pub_exc:
                    print(f"processor: republish failed, requeueing: {pub_exc}")
                    traceback.print_exc()
                    _ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
                    return

            print(f"processor: error handling message (dlq): {exc}")
            traceback.print_exc()
            publish_dlq(channel, body, reason="unhandled", error=exc, decoded_doc=doc if isinstance(doc, dict) else None)
            _ch.basic_ack(delivery_tag=method.delivery_tag)

    return _handle_message


def main() -> None:
    ensure_customer_360(get_engine())
    ensure_aggregates(get_engine())
    ensure_processed_events(get_engine())

    engine = get_engine()
    opted_out_cache: set[tuple[str, str]] = set()

    params = pika.URLParameters(settings.rabbitmq_url)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()

    ch.exchange_declare(exchange=settings.rabbitmq_exchange, exchange_type="topic", durable=True)
    ch.queue_declare(queue="sb.events.geo.q", durable=True)
    ch.queue_bind(queue="sb.events.geo.q", exchange=settings.rabbitmq_exchange, routing_key=settings.topic_geo)
    ch.queue_declare(queue="sb.events.license.q", durable=True)
    ch.queue_bind(
        queue="sb.events.license.q",
        exchange=settings.rabbitmq_exchange,
        routing_key=settings.topic_license,
    )
    ch.queue_declare(queue="sb.events.dlq.q", durable=True)
    ch.queue_bind(queue="sb.events.dlq.q", exchange=settings.rabbitmq_exchange, routing_key=settings.topic_dlq)

    ch.basic_qos(prefetch_count=50)

    consumer_id = settings.processor_group_id

    handler = make_message_handler(
        engine=engine,
        channel=ch,
        consumer_id=consumer_id,
        opted_out_cache=opted_out_cache,
    )

    ch.basic_consume(queue="sb.events.geo.q", on_message_callback=handler)
    ch.basic_consume(queue="sb.events.license.q", on_message_callback=handler)

    try:
        ch.start_consuming()
    finally:
        try:
            conn.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
