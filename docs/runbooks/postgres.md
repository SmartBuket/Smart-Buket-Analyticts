# Runbook — Postgres / DB

## Síntomas

- Processor falla con errores DBAPI/OperationalError.
- Métricas regresan cero a pesar de ingest OK.

## Diagnóstico

1) Ver contenedor:

- `docker ps` → `sb-postgres` debe estar up.

2) Ver logs del processor y del servicio afectado.

3) Verificar DSN:

- `SB_POSTGRES_DSN` debe apuntar a `localhost:15432` (local).

4) Validar schema (si se restauró volumen viejo):

- Los servicios intentan `ensure_*` en startup.
- Si algo falló, revisar logs al arranque.

## Acciones

- Si la DB quedó en estado inconsistente por cambios de schema:
  - Opción dev: bajar infra y recrear volumen (pierde data).
  - Opción prod: migraciones explícitas y versionadas.

## Consultas útiles

- Outbox pending:
  - `SELECT count(*) FROM outbox_events WHERE status='pending';`
- Dedupe processor:
  - `SELECT count(*) FROM processed_events;`
- Presencia:
  - `SELECT count(*) FROM device_hourly_presence;`
