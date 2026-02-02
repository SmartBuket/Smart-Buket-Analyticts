CREATE EXTENSION IF NOT EXISTS postgis;

-- Optional, for UUID generation in dev helpers (not strictly required by services)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Metabase application DB (prod-like): separate database/user
-- NOTE: uses psql \gexec for idempotency without transaction issues.
SELECT 'CREATE ROLE sb_metabase LOGIN PASSWORD ''sb_metabase'';'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sb_metabase')\gexec

SELECT 'CREATE DATABASE sb_metabase OWNER sb_metabase;'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'sb_metabase')\gexec

-- Administrative zoning (country/province/municipality/sector)
CREATE TABLE IF NOT EXISTS admin_areas (
  admin_id BIGSERIAL PRIMARY KEY,
  level TEXT NOT NULL CHECK (level IN ('country','province','municipality','sector')),
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  parent_code TEXT,
  geom GEOMETRY(MULTIPOLYGON, 4326) NOT NULL,
  valid_from TIMESTAMPTZ,
  valid_to TIMESTAMPTZ,
  UNIQUE(level, code)
);

CREATE INDEX IF NOT EXISTS ix_admin_areas_geom_gist ON admin_areas USING GIST (geom);
CREATE INDEX IF NOT EXISTS ix_admin_areas_level_code ON admin_areas (level, code);
CREATE INDEX IF NOT EXISTS ix_admin_areas_parent_code ON admin_areas (parent_code);

-- Raw events (immutable, schema-light)
CREATE TABLE IF NOT EXISTS raw_events (
  id BIGSERIAL PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Envelope fields (Prompt Maestro / PETS aligned)
  event_id UUID,
  trace_id UUID,
  producer TEXT,
  actor TEXT,

  app_uuid UUID NOT NULL,
  event_type TEXT NOT NULL,
  event_ts TIMESTAMPTZ NOT NULL,

  anon_user_id TEXT NOT NULL,
  device_id_hash TEXT NOT NULL,
  session_id TEXT NOT NULL,

  sdk_version TEXT NOT NULL,
  event_version TEXT NOT NULL,

  geo_point GEOMETRY(Point, 4326),
  geo_accuracy_m DOUBLE PRECISION,
  geo_source TEXT,

  payload JSONB NOT NULL,
  context JSONB NOT NULL,
  raw_doc JSONB NOT NULL
);

-- Idempotency: prevent duplicates per app/event_id
CREATE UNIQUE INDEX IF NOT EXISTS ux_raw_events_app_event_id ON raw_events (app_uuid, event_id);

CREATE INDEX IF NOT EXISTS ix_raw_events_event_id ON raw_events (event_id);
CREATE INDEX IF NOT EXISTS ix_raw_events_trace_id ON raw_events (trace_id);

CREATE INDEX IF NOT EXISTS ix_raw_events_ts ON raw_events (event_ts);
CREATE INDEX IF NOT EXISTS ix_raw_events_app_ts ON raw_events (app_uuid, event_ts);
CREATE INDEX IF NOT EXISTS ix_raw_events_type_ts ON raw_events (event_type, event_ts);
CREATE INDEX IF NOT EXISTS ix_raw_events_user_ts ON raw_events (anon_user_id, event_ts);
CREATE INDEX IF NOT EXISTS ix_raw_events_device_ts ON raw_events (device_id_hash, event_ts);
CREATE INDEX IF NOT EXISTS ix_raw_events_geo_gist ON raw_events USING GIST (geo_point);

-- Outbox Pattern (PETS): DB-transactional staging for broker publishing
CREATE TABLE IF NOT EXISTS outbox_events (
  id BIGSERIAL PRIMARY KEY,
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
);

-- Idempotency: one staged outbox row per app+event+routing_key
CREATE UNIQUE INDEX IF NOT EXISTS ux_outbox_events_app_event_routing ON outbox_events (app_uuid, event_id, routing_key);

-- Processor idempotency: avoid double-counting on redelivery
CREATE TABLE IF NOT EXISTS processed_events (
  consumer TEXT NOT NULL,
  app_uuid UUID NOT NULL,
  event_id UUID NOT NULL,
  processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer, app_uuid, event_id)
);

CREATE INDEX IF NOT EXISTS ix_outbox_events_status_next ON outbox_events (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS ix_outbox_events_app_created ON outbox_events (app_uuid, created_at);

-- Places catalog (functional zoning)
CREATE TABLE IF NOT EXISTS places (
  place_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  place_type TEXT NOT NULL,
  geofence GEOMETRY(GEOMETRY, 4326) NOT NULL,
  valid_from TIMESTAMPTZ,
  valid_to TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS ix_places_geofence_gist ON places USING GIST (geofence);

-- Hourly presence facts (strict dedupe)
-- One row per (app, hour, device) with geo dimensions.
CREATE TABLE IF NOT EXISTS device_hourly_presence (
  app_uuid UUID NOT NULL,
  hour_bucket TIMESTAMPTZ NOT NULL,
  device_id_hash TEXT NOT NULL,

  anon_user_id TEXT NOT NULL,

  h3_r7 TEXT,
  h3_r9 TEXT,
  h3_r11 TEXT,
  place_id TEXT,

  admin_country_code TEXT,
  admin_province_code TEXT,
  admin_municipality_code TEXT,
  admin_sector_code TEXT,

  geo_accuracy_m DOUBLE PRECISION,
  geo_precision_class TEXT NOT NULL,

  first_event_ts TIMESTAMPTZ NOT NULL,

  PRIMARY KEY (app_uuid, hour_bucket, device_id_hash)
);

ALTER TABLE device_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_country_code TEXT;
ALTER TABLE device_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_province_code TEXT;
ALTER TABLE device_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_municipality_code TEXT;
ALTER TABLE device_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_sector_code TEXT;

CREATE INDEX IF NOT EXISTS ix_dev_hour_app_hour ON device_hourly_presence (app_uuid, hour_bucket);
CREATE INDEX IF NOT EXISTS ix_dev_hour_h3r9_hour ON device_hourly_presence (h3_r9, hour_bucket);
CREATE INDEX IF NOT EXISTS ix_dev_hour_place_hour ON device_hourly_presence (place_id, hour_bucket);

-- One row per (app, hour, user)
CREATE TABLE IF NOT EXISTS user_hourly_presence (
  app_uuid UUID NOT NULL,
  hour_bucket TIMESTAMPTZ NOT NULL,
  anon_user_id TEXT NOT NULL,

  h3_r7 TEXT,
  h3_r9 TEXT,
  h3_r11 TEXT,
  place_id TEXT,

  admin_country_code TEXT,
  admin_province_code TEXT,
  admin_municipality_code TEXT,
  admin_sector_code TEXT,

  geo_accuracy_m DOUBLE PRECISION,
  geo_precision_class TEXT NOT NULL,

  first_event_ts TIMESTAMPTZ NOT NULL,

  PRIMARY KEY (app_uuid, hour_bucket, anon_user_id)
);

ALTER TABLE user_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_country_code TEXT;
ALTER TABLE user_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_province_code TEXT;
ALTER TABLE user_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_municipality_code TEXT;
ALTER TABLE user_hourly_presence
  ADD COLUMN IF NOT EXISTS admin_sector_code TEXT;

CREATE INDEX IF NOT EXISTS ix_user_hour_app_hour ON user_hourly_presence (app_uuid, hour_bucket);
CREATE INDEX IF NOT EXISTS ix_user_hour_h3r9_hour ON user_hourly_presence (h3_r9, hour_bucket);
CREATE INDEX IF NOT EXISTS ix_user_hour_place_hour ON user_hourly_presence (place_id, hour_bucket);

-- License state (business channel)
CREATE TABLE IF NOT EXISTS license_state (
  app_uuid UUID NOT NULL,
  anon_user_id TEXT NOT NULL,
  device_id_hash TEXT NOT NULL,

  plan_type TEXT NOT NULL,
  license_status TEXT NOT NULL,
  started_at TIMESTAMPTZ,
  renewed_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (app_uuid, anon_user_id)
);

-- Simple opt-out registry
CREATE TABLE IF NOT EXISTS opt_out (
  app_uuid UUID NOT NULL,
  anon_user_id TEXT NOT NULL,
  opted_out_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_uuid, anon_user_id)
);

-- Customer 360 (feature snapshot per anon_user_id)
-- Note: in dev, existing DB volumes won't automatically pick up new tables.
-- Services also include an "ensure schema" step so this table is created if missing.
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
);

CREATE INDEX IF NOT EXISTS ix_customer_360_last_seen ON customer_360 (last_seen_at);
CREATE INDEX IF NOT EXISTS ix_customer_360_place ON customer_360 (last_place_id);
CREATE INDEX IF NOT EXISTS ix_customer_360_h3r9 ON customer_360 (last_h3_r9);

-- Hourly aggregate tables (faster geo analytics)

-- H3 cell geometry helper table (no Postgres H3 extension required)
CREATE TABLE IF NOT EXISTS h3_cells (
  h3_cell TEXT PRIMARY KEY,
  resolution INT NOT NULL,
  geom GEOMETRY(POLYGON, 4326) NOT NULL,
  centroid GEOMETRY(Point, 4326) NOT NULL,
  centroid_lat DOUBLE PRECISION NOT NULL,
  centroid_lon DOUBLE PRECISION NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_h3_cells_geom_gist ON h3_cells USING GIST (geom);
CREATE INDEX IF NOT EXISTS ix_h3_cells_centroid_gist ON h3_cells USING GIST (centroid);
CREATE INDEX IF NOT EXISTS ix_h3_cells_resolution ON h3_cells (resolution);

CREATE TABLE IF NOT EXISTS agg_h3_r9_hourly (
  app_uuid UUID NOT NULL,
  hour_bucket TIMESTAMPTZ NOT NULL,
  h3_r9 TEXT NOT NULL,
  devices_count BIGINT NOT NULL DEFAULT 0,
  users_count BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_uuid, hour_bucket, h3_r9)
);
CREATE INDEX IF NOT EXISTS ix_agg_h3_r9_hourly_hour ON agg_h3_r9_hourly (hour_bucket);
CREATE INDEX IF NOT EXISTS ix_agg_h3_r9_hourly_h3_hour ON agg_h3_r9_hourly (h3_r9, hour_bucket);

CREATE TABLE IF NOT EXISTS agg_place_hourly (
  app_uuid UUID NOT NULL,
  hour_bucket TIMESTAMPTZ NOT NULL,
  place_id TEXT NOT NULL,
  devices_count BIGINT NOT NULL DEFAULT 0,
  users_count BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_uuid, hour_bucket, place_id)
);
CREATE INDEX IF NOT EXISTS ix_agg_place_hourly_hour ON agg_place_hourly (hour_bucket);
CREATE INDEX IF NOT EXISTS ix_agg_place_hourly_place_hour ON agg_place_hourly (place_id, hour_bucket);

CREATE TABLE IF NOT EXISTS agg_admin_hourly (
  app_uuid UUID NOT NULL,
  hour_bucket TIMESTAMPTZ NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('country','province','municipality','sector')),
  code TEXT NOT NULL,
  devices_count BIGINT NOT NULL DEFAULT 0,
  users_count BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_uuid, hour_bucket, level, code)
);
CREATE INDEX IF NOT EXISTS ix_agg_admin_hourly_hour ON agg_admin_hourly (hour_bucket);
CREATE INDEX IF NOT EXISTS ix_agg_admin_hourly_level_code_hour ON agg_admin_hourly (level, code, hour_bucket);
