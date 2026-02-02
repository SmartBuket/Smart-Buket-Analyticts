from __future__ import annotations

from datetime import datetime
from fastapi import Depends, FastAPI, HTTPException, Query
from sqlalchemy import text

from sb_common.auth import require_api_key, require_scopes
from sb_common.config import settings
from sb_common.db import get_engine
from sb_common.hardening import setup_hardening
from sb_common.metrics import add_metrics
from sb_common.observability import setup_observability
from sb_common.privacy import is_opted_out
from sb_common.rate_limit import RateLimitMiddleware, Rule, parse_rate
from sb_common.schema import ensure_aggregates, ensure_customer_360


app = FastAPI(
    title="SmartBuket Analytics Query API",
    version="0.1.0",
    dependencies=[Depends(require_api_key)],
)

setup_observability(app, log_level=settings.log_level)
setup_hardening(app)

if settings.metrics_enabled:
    add_metrics(app, service="query-api", public=settings.metrics_public)

app.add_middleware(
    RateLimitMiddleware,
    service="query-api",
    enabled=settings.rate_limit_enabled,
    rules=[
        Rule("*", "/v1/*", parse_rate(settings.rate_limit_query)),
    ],
)


@app.on_event("startup")
def _startup() -> None:
    ensure_customer_360(get_engine())
    ensure_aggregates(get_engine())


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get(
    "/v1/customers/{anon_user_id}",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def get_customer_360(anon_user_id: str, app_uuid: str | None = None) -> dict:
    where = ["anon_user_id = :anon_user_id"]
    params: dict[str, object] = {"anon_user_id": anon_user_id}
    if app_uuid:
        with get_engine().connect() as conn:
            if is_opted_out(conn, app_uuid=app_uuid, anon_user_id=anon_user_id):
                raise HTTPException(status_code=404, detail="customer not found")
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid

    sql = text(
        f"""
        SELECT
          app_uuid::text AS app_uuid,
          anon_user_id,
          device_id_hash,
          first_seen_at,
          last_seen_at,
          last_event_type,
          last_session_id,
          last_sdk_version,
          last_event_version,
          last_h3_r9,
          last_place_id,
          last_admin_country_code,
          last_admin_province_code,
          last_admin_municipality_code,
          last_admin_sector_code,
          geo_events_count,
          license_events_count,
          active_user_hours_count,
          active_device_hours_count,
          last_plan_type,
          last_license_status,
          license_started_at,
          license_renewed_at,
          license_expires_at,
          updated_at
        FROM customer_360
        WHERE {' AND '.join(where)}
        ORDER BY last_seen_at DESC
        LIMIT 1
        """
    )

    with get_engine().connect() as conn:
        row = conn.execute(sql, params).mappings().first()
    if not row:
        raise HTTPException(status_code=404, detail="customer not found")
    return dict(row)


@app.get(
    "/v1/metrics/active-devices-hourly",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def active_devices_hourly(
    start: datetime,
    end: datetime,
    app_uuid: str | None = None,
    place_id: str | None = None,
    h3_r9: str | None = None,
    country_code: str | None = None,
    province_code: str | None = None,
    municipality_code: str | None = None,
    sector_code: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params = {"start": start, "end": end}

    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if place_id:
        where.append("place_id = :place_id")
        params["place_id"] = place_id
    if h3_r9:
        where.append("h3_r9 = :h3_r9")
        params["h3_r9"] = h3_r9
    if country_code:
        where.append("admin_country_code = :country_code")
        params["country_code"] = country_code
    if province_code:
        where.append("admin_province_code = :province_code")
        params["province_code"] = province_code
    if municipality_code:
        where.append("admin_municipality_code = :municipality_code")
        params["municipality_code"] = municipality_code
    if sector_code:
        where.append("admin_sector_code = :sector_code")
        params["sector_code"] = sector_code

    sql = text(
        f"""
        SELECT hour_bucket, COUNT(*) AS dah
        FROM device_hourly_presence
        WHERE {' AND '.join(where)}
        GROUP BY hour_bucket
        ORDER BY hour_bucket
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()

    return [dict(r) for r in rows]


@app.get(
    "/v1/metrics/active-users-hourly",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def active_users_hourly(
    start: datetime,
    end: datetime,
    app_uuid: str | None = None,
    place_id: str | None = None,
    h3_r9: str | None = None,
    country_code: str | None = None,
    province_code: str | None = None,
    municipality_code: str | None = None,
    sector_code: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params = {"start": start, "end": end}

    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if place_id:
        where.append("place_id = :place_id")
        params["place_id"] = place_id
    if h3_r9:
        where.append("h3_r9 = :h3_r9")
        params["h3_r9"] = h3_r9
    if country_code:
        where.append("admin_country_code = :country_code")
        params["country_code"] = country_code
    if province_code:
        where.append("admin_province_code = :province_code")
        params["province_code"] = province_code
    if municipality_code:
        where.append("admin_municipality_code = :municipality_code")
        params["municipality_code"] = municipality_code
    if sector_code:
        where.append("admin_sector_code = :sector_code")
        params["sector_code"] = sector_code

    sql = text(
        f"""
        SELECT hour_bucket, COUNT(*) AS uah
        FROM user_hourly_presence
        WHERE {' AND '.join(where)}
        GROUP BY hour_bucket
        ORDER BY hour_bucket
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()

    return [dict(r) for r in rows]


@app.get(
    "/v1/metrics/peak-hour",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def peak_hour(
    start: datetime,
    end: datetime,
    app_uuid: str | None = None,
    place_id: str | None = None,
    h3_r9: str | None = None,
    country_code: str | None = None,
    province_code: str | None = None,
    municipality_code: str | None = None,
    sector_code: str | None = None,
    dimension: str = Query(default="devices", pattern="^(devices|users)$"),
) -> dict:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    table = "device_hourly_presence" if dimension == "devices" else "user_hourly_presence"

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params = {"start": start, "end": end}
    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if place_id:
        where.append("place_id = :place_id")
        params["place_id"] = place_id
    if h3_r9:
        where.append("h3_r9 = :h3_r9")
        params["h3_r9"] = h3_r9
    if country_code:
        where.append("admin_country_code = :country_code")
        params["country_code"] = country_code
    if province_code:
        where.append("admin_province_code = :province_code")
        params["province_code"] = province_code
    if municipality_code:
        where.append("admin_municipality_code = :municipality_code")
        params["municipality_code"] = municipality_code
    if sector_code:
        where.append("admin_sector_code = :sector_code")
        params["sector_code"] = sector_code

    sql = text(
        f"""
        SELECT hour_bucket, COUNT(*) AS value
        FROM {table}
        WHERE {' AND '.join(where)}
        GROUP BY hour_bucket
        ORDER BY value DESC
        LIMIT 1
        """
    )

    with get_engine().connect() as conn:
        row = conn.execute(sql, params).mappings().first()

    return dict(row) if row else {"hour_bucket": None, "value": 0}


@app.get(
    "/v1/aggregates/h3-r9-hourly",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def agg_h3_r9_hourly(
    start: datetime,
    end: datetime,
    app_uuid: str | None = None,
    h3_r9: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params: dict[str, object] = {"start": start, "end": end}

    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if h3_r9:
        where.append("h3_r9 = :h3_r9")
        params["h3_r9"] = h3_r9

    sql = text(
        f"""
        SELECT
          hour_bucket,
          h3_r9,
          devices_count,
          users_count
        FROM agg_h3_r9_hourly
        WHERE {' AND '.join(where)}
        ORDER BY hour_bucket, h3_r9
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/aggregates/place-hourly",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def agg_place_hourly(
    start: datetime,
    end: datetime,
    app_uuid: str | None = None,
    place_id: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params: dict[str, object] = {"start": start, "end": end}

    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if place_id:
        where.append("place_id = :place_id")
        params["place_id"] = place_id

    sql = text(
        f"""
        SELECT
          hour_bucket,
          place_id,
          devices_count,
          users_count
        FROM agg_place_hourly
        WHERE {' AND '.join(where)}
        ORDER BY hour_bucket, place_id
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/aggregates/admin-hourly",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def agg_admin_hourly(
    start: datetime,
    end: datetime,
    level: str = Query(pattern="^(country|province|municipality|sector)$"),
    app_uuid: str | None = None,
    code: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    where = ["hour_bucket >= :start", "hour_bucket < :end", "level = :level"]
    params: dict[str, object] = {"start": start, "end": end, "level": level}

    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if code:
        where.append("code = :code")
        params["code"] = code

    sql = text(
        f"""
        SELECT
          hour_bucket,
          level,
          code,
          devices_count,
          users_count
        FROM agg_admin_hourly
        WHERE {' AND '.join(where)}
        ORDER BY hour_bucket, code
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/places",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def list_places() -> list[dict]:
    sql = text(
        """
        SELECT place_id, name, place_type, valid_from, valid_to
        FROM places
        ORDER BY place_id
        """
    )
    with get_engine().connect() as conn:
        rows = conn.execute(sql).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/places/{place_id}",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def get_place(place_id: str) -> dict:
    sql = text(
        """
        SELECT place_id, name, place_type, valid_from, valid_to
        FROM places
        WHERE place_id = :place_id
        """
    )
    with get_engine().connect() as conn:
        row = conn.execute(sql, {"place_id": place_id}).mappings().first()
    if not row:
        raise HTTPException(status_code=404, detail="place not found")
    return dict(row)


@app.get(
    "/v1/places/{place_id}/metrics/recurrence",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def place_recurrence(
    place_id: str,
    start: datetime,
    end: datetime,
    dimension: str = Query(default="devices", pattern="^(devices|users)$"),
) -> list[dict]:
    """Recurrencia: cuántos días distintos un device/user aparece en el place (histograma)."""
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    if dimension == "devices":
        id_col = "device_id_hash"
        table = "device_hourly_presence"
    else:
        id_col = "anon_user_id"
        table = "user_hourly_presence"

    sql = text(
        f"""
        WITH per_entity AS (
          SELECT {id_col} AS entity_id,
                 COUNT(DISTINCT date_trunc('day', hour_bucket))::int AS days
          FROM {table}
          WHERE place_id = :place_id
            AND hour_bucket >= :start AND hour_bucket < :end
          GROUP BY {id_col}
        )
        SELECT days, COUNT(*)::int AS entities
        FROM per_entity
        GROUP BY days
        ORDER BY days
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, {"place_id": place_id, "start": start, "end": end}).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/places/{place_id}/metrics/dwell",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def place_dwell_estimate(
    place_id: str,
    start: datetime,
    end: datetime,
    dimension: str = Query(default="devices", pattern="^(devices|users)$"),
) -> dict:
    """Estimación agregada de permanencia basada en rachas horarias consecutivas."""
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    if dimension == "devices":
        id_col = "device_id_hash"
        table = "device_hourly_presence"
    else:
        id_col = "anon_user_id"
        table = "user_hourly_presence"

    sql = text(
        f"""
        WITH base AS (
          SELECT {id_col} AS entity_id,
                 date_trunc('day', hour_bucket) AS day_bucket,
                 hour_bucket
          FROM {table}
          WHERE place_id = :place_id
            AND hour_bucket >= :start AND hour_bucket < :end
        ),
        marked AS (
          SELECT entity_id,
                 day_bucket,
                 hour_bucket,
                 CASE
                   WHEN lag(hour_bucket) OVER (PARTITION BY entity_id, day_bucket ORDER BY hour_bucket)
                        = hour_bucket - interval '1 hour'
                   THEN 0 ELSE 1
                 END AS new_run
          FROM base
        ),
        runs AS (
          SELECT entity_id,
                 day_bucket,
                 hour_bucket,
                 SUM(new_run) OVER (PARTITION BY entity_id, day_bucket ORDER BY hour_bucket) AS run_id
          FROM marked
        ),
        run_lengths AS (
          SELECT entity_id, day_bucket, run_id, COUNT(*)::int AS hours
          FROM runs
          GROUP BY entity_id, day_bucket, run_id
        ),
        per_day AS (
          SELECT entity_id, day_bucket, MAX(hours)::int AS max_consecutive_hours
          FROM run_lengths
          GROUP BY entity_id, day_bucket
        )
        SELECT
          COUNT(*)::int AS entity_days,
          COALESCE(AVG(max_consecutive_hours)::float, 0.0) AS avg_max_consecutive_hours,
          COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY max_consecutive_hours), 0.0) AS p50_max_consecutive_hours,
          COALESCE(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY max_consecutive_hours), 0.0) AS p90_max_consecutive_hours
        FROM per_day
        """
    )

    with get_engine().connect() as conn:
        row = conn.execute(sql, {"place_id": place_id, "start": start, "end": end}).mappings().first()

    out = dict(row) if row else {}
    out["place_id"] = place_id
    out["dimension"] = dimension
    return out


@app.get(
    "/v1/metrics/heatmap/h3",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def heatmap_h3(
    start: datetime,
    end: datetime,
    resolution: int = Query(default=9, ge=0, le=15),
    app_uuid: str | None = None,
    metric: str = Query(default="devices", pattern="^(devices|users)$"),
    country_code: str | None = None,
    province_code: str | None = None,
    municipality_code: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    col = {7: "h3_r7", 9: "h3_r9", 11: "h3_r11"}.get(resolution)
    if col is None:
        raise HTTPException(status_code=400, detail="supported resolutions: 7, 9, 11")

    table = "device_hourly_presence" if metric == "devices" else "user_hourly_presence"

    where = ["hour_bucket >= :start", "hour_bucket < :end", f"{col} IS NOT NULL"]
    params = {"start": start, "end": end}
    if app_uuid:
        where.append("app_uuid = CAST(:app_uuid AS uuid)")
        params["app_uuid"] = app_uuid
    if country_code:
        where.append("admin_country_code = :country_code")
        params["country_code"] = country_code
    if province_code:
        where.append("admin_province_code = :province_code")
        params["province_code"] = province_code
    if municipality_code:
        where.append("admin_municipality_code = :municipality_code")
        params["municipality_code"] = municipality_code

    sql = text(
        f"""
        SELECT {col} AS h3, COUNT(*) AS value
        FROM {table}
        WHERE {' AND '.join(where)}
        GROUP BY {col}
        ORDER BY value DESC
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/metrics/app-share",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def app_share(
    start: datetime,
    end: datetime,
    place_id: str | None = None,
    h3_r9: str | None = None,
    metric: str = Query(default="devices", pattern="^(devices|users)$"),
    country_code: str | None = None,
    province_code: str | None = None,
    municipality_code: str | None = None,
) -> list[dict]:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    table = "device_hourly_presence" if metric == "devices" else "user_hourly_presence"

    where = ["hour_bucket >= :start", "hour_bucket < :end"]
    params = {"start": start, "end": end}
    if place_id:
        where.append("place_id = :place_id")
        params["place_id"] = place_id
    if h3_r9:
        where.append("h3_r9 = :h3_r9")
        params["h3_r9"] = h3_r9
    if country_code:
        where.append("admin_country_code = :country_code")
        params["country_code"] = country_code
    if province_code:
        where.append("admin_province_code = :province_code")
        params["province_code"] = province_code
    if municipality_code:
        where.append("admin_municipality_code = :municipality_code")
        params["municipality_code"] = municipality_code

    sql = text(
        f"""
        SELECT app_uuid::text AS app_uuid, COUNT(*) AS value
        FROM {table}
        WHERE {' AND '.join(where)}
        GROUP BY app_uuid
        ORDER BY value DESC
        """
    )

    with get_engine().connect() as conn:
        rows = conn.execute(sql, params).mappings().all()
    return [dict(r) for r in rows]


@app.get(
    "/v1/metrics/compare-zones",
    dependencies=[Depends(require_scopes("sb.query.read"))],
)
def compare_zones(
    start: datetime,
    end: datetime,
    a_place_id: str | None = None,
    b_place_id: str | None = None,
    a_h3_r9: str | None = None,
    b_h3_r9: str | None = None,
    metric: str = Query(default="devices", pattern="^(devices|users)$"),
) -> dict:
    if end <= start:
        raise HTTPException(status_code=400, detail="end must be > start")

    if not ((a_place_id and b_place_id) or (a_h3_r9 and b_h3_r9)):
        raise HTTPException(
            status_code=400,
            detail="provide either (a_place_id,b_place_id) or (a_h3_r9,b_h3_r9)",
        )

    table = "device_hourly_presence" if metric == "devices" else "user_hourly_presence"

    def _total(where_extra: str, params_extra: dict) -> int:
        sql = text(
            f"""
            SELECT COUNT(*)::int AS value
            FROM {table}
            WHERE hour_bucket >= :start AND hour_bucket < :end
              AND {where_extra}
            """
        )
        with get_engine().connect() as conn:
            row = conn.execute(sql, {"start": start, "end": end, **params_extra}).mappings().first()
        return int(row["value"]) if row else 0

    if a_place_id:
        a_val = _total("place_id = :v", {"v": a_place_id})
        b_val = _total("place_id = :v", {"v": b_place_id})
        return {
            "metric": metric,
            "a": {"place_id": a_place_id, "value": a_val},
            "b": {"place_id": b_place_id, "value": b_val},
        }

    a_val = _total("h3_r9 = :v", {"v": a_h3_r9})
    b_val = _total("h3_r9 = :v", {"v": b_h3_r9})
    return {
        "metric": metric,
        "a": {"h3_r9": a_h3_r9, "value": a_val},
        "b": {"h3_r9": b_h3_r9, "value": b_val},
    }
