# Retención y privacidad (operación)

## Retención
- Eventos crudos: >= 90 días (tabla `raw_events`)
- Agregados: >= 24 meses (`device_hourly_presence`, `user_hourly_presence`)

Implementación local:
- Script: `scripts/prune_data.py` (borra por antigüedad en Postgres; soporta `--dry-run`).

Este starter usa Postgres; para producción se recomienda particionado por tiempo + políticas automáticas.

### Opción A (Postgres nativo)
- Particionar `raw_events` por mes (range on `event_ts`).
- Job diario que dropee particiones > 90 días.

### Opción B (migración futura)
- Crudo en S3/Blob (Parquet) + catálogo.
- Agregados en ClickHouse/BigQuery.

## Privacidad por diseño
- Sin PII: prohibido email/teléfono/nombres.
- IDs: `anon_user_id`, `device_id_hash`, `session_id` deben ser hash no reversible.
- Exposición: solo métricas agregadas (conteos por hora/zona/place).

## Opt-out
- Endpoint: `POST /v1/opt-out` en ingest.
- Registro en tabla `opt_out` (por `app_uuid` + `anon_user_id`).
- Las apps gestionan consentimiento y llaman a este endpoint.

## Borrado (right to erasure)
- Endpoint: `POST /v1/privacy/delete` en ingest.
- Borra datos en Postgres para `(app_uuid, anon_user_id)` en tablas: `raw_events`, `license_state`, `user_hourly_presence`, `device_hourly_presence`, `customer_360`.
- Por defecto mantiene el registro `opt_out` (para que no se re-ingiera); si se desea borrarlo también, enviar `delete_opt_out=true`.
