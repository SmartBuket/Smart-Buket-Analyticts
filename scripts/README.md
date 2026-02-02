# Scripts

## run-all
Arranca todo lo necesario para el MVP:

- Infra (Docker Compose)
- APIs (ingest/query/reco)
- Outbox Publisher (publica desde Postgres a RabbitMQ)
- Processor (consumer RabbitMQ)

Uso:
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1`

Nota:
- `SB_PROCESSOR_GROUP_ID` es un remanente del consumer Kafka; con RabbitMQ no aplica para replay.

## stop-all
Detiene APIs + processor.

Uso (deja infra corriendo):
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1`

Uso (también baja infra):
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1 -DownInfra`

## status
Muestra PIDs y estado de los procesos lanzados por `run-all.ps1`.

Uso:
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1`

## demo-flow
Verifica el flujo end-to-end (ingest → outbox → RabbitMQ → processor → query/offers).

## demo-places
Importa un catálogo de places (zonificación funcional) y ejecuta el flujo end-to-end validando métricas por `place_id`.

## demo-customer360
Ejecuta el flujo end-to-end y luego consulta el snapshot de Customer 360.

## prune-data
Aplica retención borrando datos por antigüedad en Postgres.

Uso (dry-run):
- `".venv\Scripts\python.exe" .\scripts\prune_data.py --dry-run`

Uso (aplicar defaults: 90d raw, ~24 meses presence):
- `".venv\Scripts\python.exe" .\scripts\prune_data.py`

Opciones:
- `--raw-days 90` (default)
- `--presence-days 730` (default)
- `--prune-customer-360` (opcional)

## import-admin-areas
Importa zonificación administrativa (GeoJSON) a PostGIS en la tabla `admin_areas`.

## import-places
Importa zonificación funcional (GeoJSON) a PostGIS en la tabla `places`.
