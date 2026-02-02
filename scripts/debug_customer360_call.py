from __future__ import annotations

import os
import sys
from datetime import datetime, timezone


def main() -> None:
    os.environ.setdefault(
        "SB_POSTGRES_DSN",
        "postgresql+psycopg://sb:sb@localhost:15432/sb_analytics",
    )

    # Import processor module (it lives under services/processor)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    proc_dir = os.path.join(root, "services", "processor")
    sys.path.insert(0, proc_dir)

    from sb_common.event_minimal import parse_minimal_event  # noqa: E402
    from sb_common.schema import ensure_customer_360  # noqa: E402
    from sb_common.db import get_engine  # noqa: E402

    from app.worker import upsert_customer_360_from_geo, upsert_customer_360_from_license  # noqa: E402

    ensure_customer_360(get_engine())

    now = datetime.now(timezone.utc).replace(microsecond=0)

    geo_doc = {
        "app_uuid": "b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7",
        "event_type": "geo.ping",
        "timestamp": now.isoformat().replace("+00:00", "Z"),
        "anon_user_id": "u_debug",
        "device_id_hash": "d_debug",
        "session_id": "s_debug",
        "sdk_version": "1.0.0",
        "event_version": "1",
        "payload": {"reason": "debug"},
        "context": {"geo": {"lat": 18.4861, "lon": -69.9312, "accuracy_m": 25, "source": "gps"}},
    }

    lic_doc = {
        **geo_doc,
        "event_type": "license.update",
        "payload": {
            "plan_type": "subscription",
            "license_status": "expired",
            "started_at": (now.replace(year=now.year - 1)).isoformat().replace("+00:00", "Z"),
        },
    }

    geo = parse_minimal_event(geo_doc)
    upsert_customer_360_from_geo(
        geo,
        h3_r9=None,
        place_id=None,
        admin_country_code=None,
        admin_province_code=None,
        admin_municipality_code=None,
        admin_sector_code=None,
        inserted_user_hour=False,
        inserted_device_hour=False,
    )

    lic = parse_minimal_event(lic_doc)
    upsert_customer_360_from_license(
        lic,
        plan_type="subscription",
        license_status="expired",
        started_at=now,
        renewed_at=None,
        expires_at=None,
    )

    from sqlalchemy import text  # noqa: E402

    with get_engine().connect() as conn:
        rows = conn.execute(text("SELECT COUNT(*) FROM customer_360")).scalar_one()
        print("customer_360 rows:", rows)
        latest = conn.execute(
            text(
                """
                SELECT app_uuid::text, anon_user_id, geo_events_count, license_events_count
                FROM customer_360
                WHERE anon_user_id IN ('u_debug')
                ORDER BY last_seen_at DESC
                """
            )
        ).fetchall()
        print("u_debug:", latest)


if __name__ == "__main__":
    main()
