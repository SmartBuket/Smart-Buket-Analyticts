# Plan de desarrollo vs Prompt Maestro (SmartBuket Analytics)

Fecha: 2026-01-25

Este documento fija el plan paso a paso para cerrar las brechas restantes vs **Prompt Maestro / PETS v1.1**.

## Resumen de brechas pendientes (alto nivel)

- Seguridad: JWT RS256 + RBAC (scopes/roles) y hardening de endpoints sensibles.
- Rate limiting.
- Observabilidad: logs JSON + `trace_id` end-to-end + métricas operacionales.
- Idempotencia/dedupe por `event_id`.
- Resiliencia del consumer (retry/backoff/requeue + DLQ).
- Validación más estricta del envelope (modo “prod”).
- Hardening operativo (TLS/headers) y runbooks.
- Cobertura funcional P2 (familias de eventos/módulos avanzados).

## Fase P0 (seguridad base y control de acceso)

### Paso 1 — Definir objetivos y threat model

**Objetivo**: acordar modelo de seguridad y permisos (multi-tenant por `app_uuid`) y amenazas principales.

**Decisiones cerradas (según objetivo de salida a mercado 30/jun y portfolio mixto)**

1. **Tipo de autenticación**
  - JWT RS256 (OIDC) en producción.
  - API key solo para dev/migración si se necesita.

2. **Google Cloud (selección)**
  - Apps (con login): **Identity Platform / Firebase Auth**.
  - Apps (sin login): **Firebase Anonymous Auth** (sin UX de login, pero con JWT válido).
  - Integraciones (SmartComm/Exactus/Generalord): **Service Accounts + OIDC identity tokens** (Workload Identity si aplica).
  - Recomendación prod: **API Gateway/Apigee** para validación JWT + rate limiting perimetral.

3. **Tenancy / aislamiento**
   - Propuesta: cada token debe incluir `app_uuid` (claim) o `app_uuids` (lista). El backend debe:
     - Requerir `app_uuid` en endpoints que leen/filtran datos.
     - Validar que el `app_uuid` solicitado está permitido por el token.

4. **Scoping (RBAC)**
   - Propuesta de scopes mínimos:
  - `sb.ingest.write` → `POST /v1/events`
  - `sb.privacy.write` → `POST /v1/opt-out`
  - `sb.privacy.delete` → `POST /v1/privacy/delete`
  - `sb.query.read` → Query API (métricas/agregados/customer/places)
  - `sb.reco.read` → Reco API (`GET /v1/offers`)

5. **Riesgos/amenazas (threat model breve)**
   - Abuso de ingest (spam / DoS) → rate limit + auth.
   - Acceso cruzado entre apps (`app_uuid`) → scopes + validación de tenancy.
   - Replay / duplicados → idempotencia por `event_id`.
   - Exfiltración de PII → validación/filtrado + “schema-light” sin PII + controles.
   - Falta de trazabilidad → `trace_id` en logs + auditoría de acciones sensibles.

**Checklist de salida (Definition of Done para Paso 1)**

- Documento de scopes/roles + claims mínimos.
- Decisión de fuente de claves públicas (JWKS URL) y rotación.
- Decisión de estrategia de dev/local (token estático vs JWKS local).
- Endpoints “sensibles” listados (ingest/privacy/delete) y nivel de protección.

**Variables de entorno acordadas (para implementar Paso 2)**

- `SB_AUTH_MODE`:
  - `open` (dev)
  - `jwt_or_api_key` (migración)
  - `jwt` (producción recomendada)
- `SB_JWKS_URL`: JWKS del issuer (Firebase/Identity Platform o el que defina el perímetro)
- `SB_JWT_ISSUER`: issuer esperado (opcional pero recomendado)
- `SB_JWT_AUDIENCE`: audience esperado (recomendado)
- `SB_RBAC_ENFORCE`: `1` para exigir scopes en endpoints (Paso 3)

### Paso 2 — Implementar JWT RS256 + JWKS

- Agregar validación RS256 en capa común (middleware/dependency).
- Configurar:
  - `SB_JWKS_URL` (prod)
  - y/o `SB_JWT_PUBLIC_KEY` (dev/local)
- Cache de JWKS con TTL.

**Checkpoint**: sin token → 401; token inválido → 401; token válido → 200.

### Paso 3 — RBAC por endpoint

- Validar scopes por endpoint.
- Validar tenancy por `app_uuid`.

**Implementado (MVP)**

- Ingest
  - `sb.ingest.write` → `POST /v1/events`
- Privacidad
  - `sb.privacy.write` → `POST /v1/opt-out`
  - `sb.privacy.delete` → `POST /v1/privacy/delete`
- Query
  - `sb.query.read` → todos los `GET /v1/*`
- Reco
  - `sb.reco.read` → `GET /v1/offers`

**Notas**

- Claims aceptados para scopes: `scope` (string space-separated), `scopes` (list) o `scp` (list).
- Solo se exige cuando `SB_RBAC_ENFORCE=1`.

**Checkpoint**: token sin scope/tenancy → 403.

### Paso 4 — Rate limiting

- Limitar `POST /v1/events` y endpoints de privacidad.
- (Implementación actual) middleware in-app con ventana fija (memoria) para P0.
- (Prod recomendado) rate limiting perimetral con API Gateway/Apigee o backend compartido.

**Variables de entorno**

- `SB_RATE_LIMIT_ENABLED=1`
- `SB_RATE_LIMIT_INGEST_EVENTS` (default `120/60`)
- `SB_RATE_LIMIT_PRIVACY` (default `30/60`)
- `SB_RATE_LIMIT_QUERY` (default `300/60`)
- `SB_RATE_LIMIT_RECO` (default `120/60`)

**Checkpoint**: exceso → 429 (incluye headers `X-RateLimit-*`).

## Fase P1 (observabilidad, idempotencia y resiliencia)

### Paso 5 — Logging JSON + `trace_id`

- Middleware que:
  - Acepte `X-Trace-Id` o `X-Request-Id` o genere uno.
  - Añada `X-Trace-Id` a respuestas.
  - Exponga `request.state.trace_id`.
- Logging JSON a `stdout` (configurable con `SB_LOG_LEVEL`).

### Paso 6 — Métricas `/metrics` (Prometheus)

- Endpoint Prometheus `/metrics` en las APIs.
- Métricas HTTP base:
  - `sb_http_requests_total{service,method,path,status}`
  - `sb_http_request_duration_seconds{service,method,path}`
- Métrica de rate limiting:
  - `sb_rate_limited_total{service,method,path}`

**Variables de entorno**

- `SB_METRICS_ENABLED=1` (default)
- `SB_METRICS_PUBLIC=0` (default). Si `1`, monta un sub-app en `/metrics` que no hereda dependencias globales (útil si la API principal está protegida).

### Paso 7 — Idempotencia por `event_id`

**Implementado**

- DB constraints:
  - `raw_events`: `UNIQUE(app_uuid, event_id)`
  - `outbox_events`: `UNIQUE(app_uuid, event_id, routing_key)`
- Ingest:
  - `INSERT ... ON CONFLICT DO NOTHING` para dedupe real.
  - Respuesta incluye `deduped`.
- Processor:
  - Tabla `processed_events(consumer, app_uuid, event_id)` para evitar doble conteo en redelivery.

### Paso 8 — Retry/requeue en processor

**Implementado (MVP)**

- Clasifica errores transitorios (DB/network) vs permanentes.
- Transitorios: re-publica el mensaje al mismo `routing_key` con header `sb_retry` y backoff exponencial, hasta `SB_PROCESSOR_MAX_RETRIES`.
- Permanentes o excedido max: publica a DLQ y `ack`.

**Variables de entorno**

- `SB_PROCESSOR_MAX_RETRIES` (default `5`)
- `SB_PROCESSOR_RETRY_BASE_SECONDS` (default `0.5`)
- `SB_PROCESSOR_RETRY_MAX_SECONDS` (default `10`)

### Paso 9 — Endurecer validación del envelope

**Implementado**

- `SB_STRICT_ENVELOPE=1` hace que el parser rechace eventos que no cumplan con el envelope Prompt Maestro.
- Campos requeridos en modo estricto: `event_name`, `occurred_at`, `event_id`, `trace_id`, `producer`, `actor`.
- En modo estricto no se generan defaults automáticos (para que el producer sea responsable del contrato).

## Fase P2 (operación y cobertura funcional)

### Paso 10 — Hardening operativo (TLS/headers)

**Implementado (MVP)**

- Middleware opcional por env para headers de hardening + CORS.
- Se activa por servicio (FastAPI) sin romper dev.

**Variables de entorno**

- `SB_HARDENING_ENABLED=1`
- `SB_HSTS_SECONDS` (default `31536000`). Nota: habilitar solo detrás de HTTPS.
- `SB_HSTS_PRELOAD=0|1`
- `SB_CORS_ALLOW_ORIGINS` (CSV), ejemplo: `https://app.smartbuket.com,https://admin.smartbuket.com`

### Paso 11 — Cobertura de eventos y módulos P2

**Implementado (base de enrutamiento + documentación)**

- Familias P2 enrutadas a routing keys dedicadas (además de `raw`).
- Documentación: ver [docs/events-p2.md](docs/events-p2.md).

Pendiente (producto): definir materializaciones/consumidores P2 concretos (engagement, funnels, crash rate, etc.).

### Paso 12 — Pruebas E2E y runbooks

**Implementado (MVP)**

- Script E2E asertivo: [scripts/e2e-smoke.ps1](scripts/e2e-smoke.ps1).
- Runbooks: ver [docs/runbooks/README.md](docs/runbooks/README.md).
