from __future__ import annotations

import os

from sqlalchemy import inspect, text

from sb_common.db import get_engine


def main() -> None:
    os.environ.setdefault(
        "SB_POSTGRES_DSN",
        "postgresql+psycopg://sb:sb@localhost:15432/sb_analytics",
    )

    engine = get_engine()
    insp = inspect(engine)

    has = insp.has_table("customer_360")
    print("has_table customer_360:", has)
    if not has:
        return

    with engine.connect() as conn:
        rows = conn.execute(text("SELECT COUNT(*) FROM customer_360")).scalar_one()
        print("rows:", rows)

        latest = conn.execute(
            text(
                """
                SELECT
                  app_uuid::text AS app_uuid,
                  anon_user_id,
                  geo_events_count,
                  license_events_count,
                  active_user_hours_count,
                  active_device_hours_count,
                  last_seen_at,
                  updated_at
                FROM customer_360
                ORDER BY last_seen_at DESC
                LIMIT 5
                """
            )
        ).mappings().all()
        print("latest:")
        for r in latest:
            print(dict(r))


if __name__ == "__main__":
    main()
