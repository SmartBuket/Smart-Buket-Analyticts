from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.engine import Engine


def ensure_raw_events_envelope(engine: Engine) -> None:
    ddl_statements = [
        """ALTER TABLE raw_events ADD COLUMN IF NOT EXISTS event_id UUID""",
        """ALTER TABLE raw_events ADD COLUMN IF NOT EXISTS trace_id UUID""",
        """ALTER TABLE raw_events ADD COLUMN IF NOT EXISTS producer TEXT""",
        """ALTER TABLE raw_events ADD COLUMN IF NOT EXISTS actor TEXT""",
        """CREATE INDEX IF NOT EXISTS ix_raw_events_event_id ON raw_events (event_id)""",
        """CREATE INDEX IF NOT EXISTS ix_raw_events_trace_id ON raw_events (trace_id)""",
        """CREATE UNIQUE INDEX IF NOT EXISTS ux_raw_events_app_event_id ON raw_events (app_uuid, event_id)""",
    ]

    with engine.begin() as conn:
        for stmt in ddl_statements:
            conn.execute(text(stmt))


def ensure_outbox(engine: Engine) -> None:
    ddl_statements = [
                """CREATE SEQUENCE IF NOT EXISTS outbox_events_id_seq""",
        """
        CREATE TABLE IF NOT EXISTS outbox_events (
                    id BIGINT NOT NULL DEFAULT nextval('outbox_events_id_seq') PRIMARY KEY,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          locked_at TIMESTAMPTZ,

          app_uuid UUID NOT NULL,
          event_id UUID,
          trace_id UUID,
          occurred_at TIMESTAMPTZ NOT NULL,

          routing_key TEXT NOT NULL,
          payload JSONB NOT NULL,

          status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed')),
          retries INT NOT NULL DEFAULT 0,
          next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          last_error TEXT
        )
        """,
        """CREATE INDEX IF NOT EXISTS ix_outbox_events_status_next ON outbox_events (status, next_attempt_at)""",
        """CREATE INDEX IF NOT EXISTS ix_outbox_events_app_created ON outbox_events (app_uuid, created_at)""",
        """CREATE UNIQUE INDEX IF NOT EXISTS ux_outbox_events_app_event_routing ON outbox_events (app_uuid, event_id, routing_key)""",
    ]

    with engine.begin() as conn:
        for stmt in ddl_statements:
            conn.execute(text(stmt))


def ensure_processed_events(engine: Engine) -> None:
    ddl_statements = [
        """
        CREATE TABLE IF NOT EXISTS processed_events (
          consumer TEXT NOT NULL,
          app_uuid UUID NOT NULL,
          event_id UUID NOT NULL,
          processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          PRIMARY KEY (consumer, app_uuid, event_id)
        )
        """,
    ]

    with engine.begin() as conn:
        for stmt in ddl_statements:
            conn.execute(text(stmt))


def ensure_customer_360(engine: Engine) -> None:
    """Creates Customer 360 schema if missing.

    This is intentionally lightweight for local/dev where docker volumes may
    already exist and won't re-run `infra/init.sql`.
    """

    ddl_statements = [
        """
        CREATE TABLE IF NOT EXISTS customer_360 (
          app_uuid UUID NOT NULL,
          anon_user_id TEXT NOT NULL,
          device_id_hash TEXT,

          first_seen_at TIMESTAMPTZ NOT NULL,
          last_seen_at TIMESTAMPTZ NOT NULL,
          last_event_type TEXT,
          last_session_id TEXT,
          last_sdk_version TEXT,
          last_event_version TEXT,

          last_h3_r9 TEXT,
          last_place_id TEXT,
          last_admin_country_code TEXT,
          last_admin_province_code TEXT,
          last_admin_municipality_code TEXT,
          last_admin_sector_code TEXT,

          geo_events_count BIGINT NOT NULL DEFAULT 0,
          license_events_count BIGINT NOT NULL DEFAULT 0,
          active_user_hours_count BIGINT NOT NULL DEFAULT 0,
          active_device_hours_count BIGINT NOT NULL DEFAULT 0,

          last_plan_type TEXT,
          last_license_status TEXT,
          license_started_at TIMESTAMPTZ,
          license_renewed_at TIMESTAMPTZ,
          license_expires_at TIMESTAMPTZ,

          updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

          PRIMARY KEY (app_uuid, anon_user_id)
        )
        """,
        """CREATE INDEX IF NOT EXISTS ix_customer_360_last_seen ON customer_360 (last_seen_at)""",
        """CREATE INDEX IF NOT EXISTS ix_customer_360_place ON customer_360 (last_place_id)""",
        """CREATE INDEX IF NOT EXISTS ix_customer_360_h3r9 ON customer_360 (last_h3_r9)""",
    ]

    with engine.begin() as conn:
        for stmt in ddl_statements:
            conn.execute(text(stmt))


def ensure_aggregates(engine: Engine) -> None:
        """Creates aggregate tables used for faster geo analytics.

        Like ensure_customer_360, this is for dev/local where `infra/init.sql`
        might not re-run for existing DB volumes.
        """

        ddl_statements = [
            # H3 cell geometry helper table (no Postgres H3 extension required)
            # Populated by the processor on-demand.
            """
            CREATE TABLE IF NOT EXISTS h3_cells (
                h3_cell TEXT PRIMARY KEY,
                resolution INT NOT NULL,
                geom GEOMETRY(POLYGON, 4326) NOT NULL,
                centroid GEOMETRY(Point, 4326) NOT NULL,
                centroid_lat DOUBLE PRECISION NOT NULL,
                centroid_lon DOUBLE PRECISION NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """,
            """CREATE INDEX IF NOT EXISTS ix_h3_cells_geom_gist ON h3_cells USING GIST (geom)""",
            """CREATE INDEX IF NOT EXISTS ix_h3_cells_centroid_gist ON h3_cells USING GIST (centroid)""",
            """CREATE INDEX IF NOT EXISTS ix_h3_cells_resolution ON h3_cells (resolution)""",

                # H3 r9 hourly aggregates
                """
                CREATE TABLE IF NOT EXISTS agg_h3_r9_hourly (
                    app_uuid UUID NOT NULL,
                    hour_bucket TIMESTAMPTZ NOT NULL,
                    h3_r9 TEXT NOT NULL,
                    devices_count BIGINT NOT NULL DEFAULT 0,
                    users_count BIGINT NOT NULL DEFAULT 0,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    PRIMARY KEY (app_uuid, hour_bucket, h3_r9)
                )
                """,
                """CREATE INDEX IF NOT EXISTS ix_agg_h3_r9_hourly_hour ON agg_h3_r9_hourly (hour_bucket)""",
                """CREATE INDEX IF NOT EXISTS ix_agg_h3_r9_hourly_h3_hour ON agg_h3_r9_hourly (h3_r9, hour_bucket)""",

                # Place hourly aggregates
                """
                CREATE TABLE IF NOT EXISTS agg_place_hourly (
                    app_uuid UUID NOT NULL,
                    hour_bucket TIMESTAMPTZ NOT NULL,
                    place_id TEXT NOT NULL,
                    devices_count BIGINT NOT NULL DEFAULT 0,
                    users_count BIGINT NOT NULL DEFAULT 0,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    PRIMARY KEY (app_uuid, hour_bucket, place_id)
                )
                """,
                """CREATE INDEX IF NOT EXISTS ix_agg_place_hourly_hour ON agg_place_hourly (hour_bucket)""",
                """CREATE INDEX IF NOT EXISTS ix_agg_place_hourly_place_hour ON agg_place_hourly (place_id, hour_bucket)""",

                # Admin hourly aggregates (country/province/municipality/sector)
                """
                CREATE TABLE IF NOT EXISTS agg_admin_hourly (
                    app_uuid UUID NOT NULL,
                    hour_bucket TIMESTAMPTZ NOT NULL,
                    level TEXT NOT NULL CHECK (level IN ('country','province','municipality','sector')),
                    code TEXT NOT NULL,
                    devices_count BIGINT NOT NULL DEFAULT 0,
                    users_count BIGINT NOT NULL DEFAULT 0,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    PRIMARY KEY (app_uuid, hour_bucket, level, code)
                )
                """,
                """CREATE INDEX IF NOT EXISTS ix_agg_admin_hourly_hour ON agg_admin_hourly (hour_bucket)""",
                """CREATE INDEX IF NOT EXISTS ix_agg_admin_hourly_level_code_hour ON agg_admin_hourly (level, code, hour_bucket)""",
        ]

        with engine.begin() as conn:
                for stmt in ddl_statements:
                        conn.execute(text(stmt))
