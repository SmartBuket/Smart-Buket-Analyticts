# SmartBuket Analytics

Plataforma centralizada de analítica **event-driven**, **schema-light**, con soporte **geoespacial** nativo y privacidad por diseño.

## Componentes (starter)
- `services/ingest-api`: recibe eventos HTTP, guarda crudo y registra outbox (no publica directo)
- `services/outbox-publisher`: publica eventos del outbox al broker (PETS Outbox Pattern)
- `services/processor`: consume eventos y genera agregados horarios (DAH/UAH, H3, places)
- `services/query-api`: APIs mínimas de consulta (métricas agregadas)
- `services/reco-api`: `GET /offers` (reglas determinísticas) sobre Customer 360
- `infra/docker-compose.yml`: Postgres+PostGIS + RabbitMQ

## Principios obligatorios (cumplidos)
- Event-driven y desacoplado por bus
- Schema-light (solo mínimos)
- Privacidad por diseño (sin PII; IDs hash)
- Geoespacial (PostGIS + H3)
- Crudo + agregados + features para IA futura

## Quickstart (local)
1. Requiere Docker Desktop.

Ruta recomendada (Windows / PowerShell):
- Arrancar infra + APIs + processor:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1`
- Ver estado/PIDs:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1`
- Parar APIs + processor (deja infra corriendo):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1`
- Parar todo (incluye infra):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1 -DownInfra`

Ruta manual:
2. Levantar infraestructura:
    - `docker compose -f infra/docker-compose.yml up -d`

3. En cada servicio Python:
    - `pip install -r requirements.txt`
    (incluye `-e ../../libs/sb_common`)

Luego ejecutar cada servicio (ver README en cada carpeta).

## GUIs (rápido para ver algo)
   - Ingest: `http://localhost:8001/docs`
   - Query: `http://localhost:8002/docs`
   - Offers: `http://localhost:8003/docs`
   - RabbitMQ (Management UI): `http://localhost:15672` (dev: `guest/guest`)
   - pgAdmin: `http://localhost:5050/browser/`
   - Metabase (dashboards): `http://localhost:3001/`
   - Prometheus: `http://localhost:9090/`
   - Grafana: `http://localhost:3002/` (dev: `admin/admin`)

## Nota RabbitMQ

- UI: `http://localhost:15672` (credenciales dev: `guest/guest`)

## Demo end-to-end (PowerShell)
- Ejecuta [scripts/demo-flow.ps1](scripts/demo-flow.ps1) para enviar `geo.ping` + `license.*` y consultar métricas + offers.

## E2E smoke test (automatizado)

- Smoke “asertivo” (arranca stack, valida hardening/strict envelope, publica eventos y verifica métricas + offers):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\e2e-smoke.ps1 -StartStack -Hardening -StrictEnvelope -WaitSeconds 20`
- Útil para CI local o validación rápida post-cambio.

## Runbooks (operación)

- Ver [docs/runbooks/README.md](docs/runbooks/README.md) para guías de outbox, DLQ, RabbitMQ, Postgres y seguridad.

## Dashboards (Metabase)

Metabase viene incluido en la infra local (ver `infra/docker-compose.yml`).

- UI: `http://localhost:3001/`
- Setup inicial (recomendado, 1 vez):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\metabase-bootstrap.ps1`
   - Esto configura el Site name como "SmartBuket Analytics", agrega la DB `sb_analytics` y (por defecto) elimina la "Sample Database".

- Crear el primer dashboard (cards + dashboard):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\metabase-create-starter-dashboard.ps1 -UseDockerAutodetect`
   - Es idempotente: si el dashboard ya existe, lo reutiliza/actualiza (no duplica dashboards en cada corrida).
   - Si tienes más de una app, puedes pasar `-AppUuid <uuid>` para elegir.
   - El filtro **App** queda como dropdown (Metabase lo alimenta desde una card auxiliar de `app_uuid`).
   - Incluye una fila KPI (DAH/UAH avg + peak) arriba del todo.
   - Incluye un **mapa de places** (pin map) usando `places.geofence` (centroid) + agregados de `agg_place_hourly`.
   - Nota H3: el stack trae PostGIS, pero no trae extensión H3 en Postgres. Para poder mapear H3 igual, se genera la tabla `h3_cells` (polígono + centroide) y el processor la va poblando on-demand.
      - Para mapas en Metabase: usa `h3_cells.centroid` (point) o `h3_cells.polygon` (shape) junto a tus agregados por celda (por ejemplo `agg_h3_hourly`).
   - El filtro **Date range** tiene default `past7days` (cambiable con `-DateRangeDefault`).
   - Nota: Metabase exige un password no-trivial (por ejemplo `Admin!23456`).
- Para conectarlo a la DB del stack:
   - DB type: Postgres
   - Host: `sb-postgres` (o `postgres` si usas el nombre del servicio)
   - Port: `5432`
   - Database: `sb_analytics`
   - User/Password: `sb` / `sb`

Nota: si conectas desde tu host (no desde Metabase dentro de Docker), el host es `localhost` y el puerto es `15432`.

Si ves el título "SmartComm" (u otro): es solo el **Site name** de Metabase (configurable en Admin → Settings → General). Si querés resetear únicamente Metabase (sin tocar Postgres), borra el volumen `infra_sb_metabase` y reinicia el servicio.

## E2E smoke (asertivo)

- Script: [scripts/e2e-smoke.ps1](scripts/e2e-smoke.ps1)
- Ejemplo (levantar stack + hardening + strict):
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\e2e-smoke.ps1 -StartStack -Hardening -StrictEnvelope`

## Familias de eventos P2

Además de `geo.*` y `license.*`, el ingest puede enrutar familias P2 a routing keys dedicadas (además de `sb.events.raw`):

- `session.*` → `sb.events.session`
- `screen.*` → `sb.events.screen`
- `ui.*` → `sb.events.ui`
- `system.*` → `sb.events.system`

Detalles: [docs/events-p2.md](docs/events-p2.md)

## Auth (dev vs prod)

Las APIs (`ingest-api`, `query-api`, `reco-api`) usan el dependency `require_api_key` de `sb_common`, controlado por variables de entorno:

- `SB_AUTH_MODE`:
   - `open` (default): sin auth (local/dev)
   - `api_key`: requiere `SB_API_KEY`
   - `jwt`: requiere `Authorization: Bearer <jwt>` validado con `SB_JWKS_URL` (RS256)
   - `jwt_or_api_key`: acepta JWT o API key (migración)
- `SB_JWKS_URL`: URL del JWKS del issuer
- `SB_JWT_ISSUER` / `SB_JWT_AUDIENCE`: validación adicional (recomendado en prod)
- `SB_RBAC_ENFORCE=1`: activa chequeo de scopes (Paso 3 del plan)

## Rate limiting (P0)

Hay un rate limit in-app (ventana fija, memoria) pensado para dev/P0. En producción se recomienda hacerlo en el perímetro (API Gateway/Apigee).

- `SB_RATE_LIMIT_ENABLED=1`
- `SB_RATE_LIMIT_INGEST_EVENTS` (default `120/60`)
- `SB_RATE_LIMIT_PRIVACY` (default `30/60`)
- `SB_RATE_LIMIT_QUERY` (default `300/60`)
- `SB_RATE_LIMIT_RECO` (default `120/60`)

## Logging + trace id

- `SB_LOG_LEVEL` (default `INFO`)
- Header `X-Trace-Id`: si lo envías, se propaga; si no, se genera.

## Métricas (Prometheus)

Cada API expone `/metrics` con métricas Prometheus (HTTP + rate limit).

- `SB_METRICS_ENABLED=1` (default)
- `SB_METRICS_PUBLIC=0` (default). Si `1`, `/metrics` queda fuera de auth global (recomendado solo en redes internas/perímetro).

Infra observabilidad (local):
- Prometheus corre en `http://localhost:9090/` (scrapea `host.docker.internal:8001/8002/8003/metrics`).
- Grafana corre en `http://localhost:3002/` (dev: `admin/admin`) y trae un dashboard provisionado.

Modo VM Linux (sin Docker Desktop):
- Prometheus puede usar scraping por DNS interno de Compose (sin `host.docker.internal`).
   - Selección de config se hace en `docker compose` (variable de entorno del host):
      - PowerShell: `$env:PROM_CONFIG="prometheus.docker.yml"; docker compose -f infra/docker-compose.yml up -d`
      - bash: `PROM_CONFIG=prometheus.docker.yml docker compose -f infra/docker-compose.yml up -d`
   - Levantar APIs como contenedores con el profile `beta`.

## Beta/staging: query-api en Docker (opcional)

Para un entorno más parecido a prod (sin depender de procesos en el host), puedes correr `query-api` como contenedor.

- Levantar solo `query-api` en Docker (manteniendo el resto como está):
   - `docker compose -f infra/docker-compose.yml --profile beta up -d query-api`
   - Queda disponible en `http://localhost:8002/docs` y Prometheus lo scrapeará por el mismo puerto.
- Alternativa: usar el runner y pedirle que use Docker solo para `query-api`:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1 -UseDockerQueryApi`

Para correr las 3 APIs en Docker (recomendado en VM/staging):
- `docker compose -f infra/docker-compose.yml --profile beta up -d ingest-api query-api reco-api`
- O con el runner:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1 -UseDockerIngestApi -UseDockerQueryApi -UseDockerRecoApi`

## Deploy en Google Cloud (Cloud Run)

- Infra + Cloud SQL + Secret Manager + Cloud Run (Terraform): ver [infra/gcp/terraform/README.md](infra/gcp/terraform/README.md)
- CI/CD (Cloud Build): ver [infra/gcp/cloudbuild/cloudbuild.yaml](infra/gcp/cloudbuild/cloudbuild.yaml)
- Bootstrap 100% automático: ver [infra/gcp/cloudbuild/cloudbuild-bootstrap.yaml](infra/gcp/cloudbuild/cloudbuild-bootstrap.yaml)

## Envelope estricto (Prompt Maestro)

- `SB_STRICT_ENVELOPE=1`: rechaza eventos que no traigan el envelope Prompt Maestro completo (`event_name`, `occurred_at`, `event_id`, `trace_id`, `producer`, `actor`).
- Contrato JSON Schema: `contracts/event-prompt-maestro.schema.json`.

## Hardening (headers/CORS)

Middleware opcional (por env) para headers de hardening + CORS.

- `SB_HARDENING_ENABLED=1`
- `SB_HSTS_SECONDS` (default `31536000`) y `SB_HSTS_PRELOAD=0|1` (habilitar solo detrás de HTTPS / reverse-proxy)
- `SB_CORS_ALLOW_ORIGINS` (CSV). Si no se define, no se habilita CORS.

## Troubleshooting (local)
- `ERR_CONNECTION_REFUSED` en `http://localhost:8001/docs` (o 8002/8003):
   - No hay nada escuchando en ese puerto. Solución:
      - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1`

- `ERR_CONNECTION_REFUSED` en `http://localhost:15672` (RabbitMQ UI) o `http://localhost:5050/browser/` (pgAdmin):
   - Infra está abajo (por ejemplo, se ejecutó `stop-all.ps1 -DownInfra`). Solución:
      - `docker compose -f infra/docker-compose.yml up -d`

- Puertos ocupados (`8001/8002/8003`):
   - Solución recomendada:
      - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1`
      - y luego `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1`

- Ver qué está corriendo / PIDs:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1`

- Ver logs (cada corrida genera un `RunId`):
   - `Get-ChildItem .\scripts\logs | Sort-Object LastWriteTime -Descending | Select-Object -First 20`

## Zonificación administrativa
- Guía: [docs/admin-zoning.md](docs/admin-zoning.md)
- Importar boundaries (GeoJSON provisto por tu org):
   - `powershell -File scripts/import-admin-areas.ps1 -GeoJsonPath .\admin_areas.geojson`

## Places (zonificación funcional)
- Guía: [docs/places.md](docs/places.md)
- Importar places (GeoJSON provisto por tu org):
   - `powershell -File scripts/import-places.ps1 -GeoJsonPath .\places.geojson`

