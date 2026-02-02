# Auditoría vs PROMPT MAESTRO — SmartBuket Analytics (alineado PETS v1.1)

Fecha: 2026-01-25

Actualización: el repo ya fue migrado a **RabbitMQ + Outbox Pattern** (por lo que varias brechas de este informe quedaron resueltas).

Este documento audita el estado actual del repo contra el **PROMPT MAESTRO — SmartBuket Analytics** (alineado a **PETS v1.1**) y marca **cumplimientos**, **parciales** y **brechas**.

## Fuentes revisadas (evidencia)

- [README.md](../README.md)
- [docs/pets-v1.1.md](pets-v1.1.md)
- [infra/docker-compose.yml](../infra/docker-compose.yml)
- [infra/init.sql](../infra/init.sql)
- [contracts/event-core.schema.json](../contracts/event-core.schema.json)
- [contracts/commercial-events.md](../contracts/commercial-events.md)
- [contracts/geo-ping.example.json](../contracts/geo-ping.example.json)
- [services/ingest-api/app/main.py](../services/ingest-api/app/main.py)
- [services/processor/app/worker.py](../services/processor/app/worker.py)
- [services/query-api/app/main.py](../services/query-api/app/main.py)
- [services/reco-api/app/main.py](../services/reco-api/app/main.py)
- [libs/sb_common/sb_common/event_minimal.py](../libs/sb_common/sb_common/event_minimal.py)
- [libs/sb_common/sb_common/auth.py](../libs/sb_common/sb_common/auth.py)
- [libs/sb_common/sb_common/config.py](../libs/sb_common/sb_common/config.py)
- [docs/topics-and-partitioning.md](topics-and-partitioning.md)
- [docs/retention-and-privacy.md](retention-and-privacy.md)
- [scripts/demo-flow.ps1](../scripts/demo-flow.ps1)
- [services/outbox-publisher/app/worker.py](../services/outbox-publisher/app/worker.py)

## Resumen ejecutivo

**Lo que está bien encaminado (alineación fuerte con el Prompt):**

- Arquitectura desacoplada por bus: ingest escribe en DB + outbox, outbox-publisher publica a RabbitMQ, processor consume, query expone agregados.
- Modelo **schema-light**: valida un contrato mínimo y no fuerza payloads rígidos para geo (salvo mínimos del core).
- Soporte geoespacial: PostGIS + H3 (res 7/9/11), y zonificación administrativa + funcional (places).
- Preservación de crudos + materializaciones: `raw_events`, tablas de presencia horaria y agregados.
- Dedupe por hora (DAH/UAH): claves primarias por `(app_uuid, hour_bucket, device_id_hash)` y `(app_uuid, hour_bucket, anon_user_id)`.
- Opt-out y borrado por usuario (a nivel de DB) están implementados.

**Brechas mayores (alineación PETS/Prompt):**

- **Envelope PETS/Prompt**: 🟡 (ya se aceptan `event_name/occurred_at/event_id/trace_id/producer/actor`, pero sigue existiendo compat con `event_type/timestamp` y conviene endurecer validación/idempotencia por `event_id`).
- **Seguridad**: el Prompt/PETS fijan JWT RS256 + RBAC; hoy se usa API key opcional y no hay scopes/roles.
- **Observabilidad**: no hay `trace_id` end-to-end ni logs estructurados consistentes.

## Matriz de cumplimiento (Prompt Maestro)

Leyenda: ✅ Cumple | 🟡 Parcial | ❌ Brecha

### 1) Arquitectura y desacoplamiento

- Event-driven (bus) y apps desacopladas: ✅ (RabbitMQ + Outbox)
- Apps ↔ Analytics solo vía SDKs oficiales: 🟡 (hay endpoint HTTP; no se puede verificar “SDK-only” desde el backend)
- Integración por contrato: 🟡 (hay JSON Schema mínimo; no hay OpenAPI/contratos versionados formalmente en un “repo único”)

### 2) RabbitMQ + Outbox Pattern (PETS)

- Broker RabbitMQ topic/durable: ✅ (RabbitMQ en [infra/docker-compose.yml](../infra/docker-compose.yml))
- DLQ por consumidor: ✅ (topic `sb.events.dlq` y publisher en processor)
- Retry con backoff exponencial: 🟡 (outbox-publisher implementa backoff; processor enruta a DLQ en fallos)
- Outbox Pattern: ✅ (tabla `outbox_events` + servicio outbox-publisher)

### 3) Envelope estándar y validación mínima

Prompt esperado:

- `event_id`, `event_name`, `event_version`, `occurred_at`, `trace_id`, `app_uuid`, `producer`, `actor`, `payload`, `context.geo.*`

Implementación actual (core mínimo):

- `app_uuid`, `event_type`, `timestamp`, `anon_user_id`, `device_id_hash`, `session_id`, `sdk_version`, `event_version`, `payload`, `context`

Resultado:

- Envelope: 🟡 (equivalencias parciales, pero faltan campos y naming del Prompt)
- “Analytics NO interpreta payload”: 🟡 (geo agrega sin depender del payload; pero `license.*` y offers sí interpretan payload/event_type)

### 4) Geo y zonificación

- `geo.ping` soportado: ✅
- H3 multi-res (7/9/11): ✅
- Zonificación administrativa (country/province/municipality/sector): ✅
- Places (geofence) + vigencia: ✅ (tabla `places`)
- Calidad/precisión: 🟡 (clasifica precision y degrada niveles finos con precisión “coarse”; falta anomalías geográficas explícitas)

### 5) Métricas fundamentales y APIs mínimas

- DAH por hora: ✅ (Query API)
- UAH por hora: ✅
- Hora pico: ✅
- Heatmaps: ✅ (H3)
- Share por aplicación (por zona/place/h3): ✅
- Comparativas territoriales: ✅ (compare-zones)

### 6) Privacidad y cumplimiento

- Sin PII (contrato y docs): ✅
- IDs anonimizados: ✅ (contrato exige longitudes mínimas; el backend no puede verificar “no reversibles”)
- Opt-out: ✅
- Right to erasure (DB): ✅
- Retención (crudos >= 90d, agregados >= 24m): 🟡 (documentado; se apoya en script de prune; falta enforcement automático)

### 7) Customer Intelligence & Offers

- Fuentes permitidas:
  - Licencias: ✅ (tabla `license_state`)
  - Eventos Analytics: ✅ (`raw_events`)
- Customer 360 entidad lógica: 🟡 (tabla `customer_360` existe con señales; faltan dimensiones/métricas completas del prompt)
- Offers API: ✅ (`GET /v1/offers`)
- “Apps solo consumen, no deciden”: ✅ (ofertas determinísticas del lado server)
- Opt-out aplicado: ✅

### 8) Seguridad y operación (PETS)

- JWT RS256 + claims y rotación: ❌
- RBAC mínimo + auditoría de acciones: ❌
- Rate limit en endpoints críticos: ❌
- TLS/headers de seguridad: ❌ (no se ve en app; dependerá de reverse proxy)
- Logs estructurados JSON + trace_id: ❌
- Docker + compose dev: ✅

## Observaciones técnicas (riesgos)

- Riesgo de inconsistencia DB↔bus: ingest inserta `raw_events` y publica al bus sin outbox; ante fallos parciales podrían existir eventos en DB que nunca se procesen, o eventos publicados que no queden guardados.
- Falta `event_id`/idempotencia de crudo: `raw_events` no tiene clave natural de dedupe por evento; reintentos pueden duplicar crudos (aunque agregados por hora están deduplicados por PK).
- Falta `trace_id`: dificulta troubleshooting y auditoría end-to-end.

## Backlog recomendado (priorizado)

### P0 (alineación PETS/Prompt y seguridad)

1. Endurecer autenticación/autorización:
   - JWT RS256 (si aplica a servicios internos)
   - scopes/roles mínimos para endpoints sensibles (ingest privacy/delete)
2. Introducir `trace_id` obligatorio (mínimo: aceptar y propagar; ideal: generar si falta).

### P1 (calidad, resiliencia, observabilidad)

5. Retry/backoff controlado (processor): estrategia explícita y/o requeue (si broker lo soporta) + separación de errores transitorios vs permanentes.
6. Logs estructurados en JSON en todos los servicios y correlación por `trace_id`.
7. Dedupe de crudos por `event_id` (cuando el envelope sea actualizado).

### P2 (cobertura funcional del Prompt)

8. Completar familias oficiales `session.*`, `screen.*`, `ui.*`, `system.*` (hoy se soportan pero no se materializan explícitamente).
9. Anomalías geográficas (básico): outliers por velocidad/teleport, precisión inconsistente.
10. Completar Customer 360 según prompt (DAU/WAU/MAU, engagement score, señales comerciales).

## Conclusión

El repo actual cumple gran parte de la intención del Prompt Maestro en **métricas geo, desacoplamiento y privacidad**, pero no está completamente “PETS compliant” por dos puntos estructurales: **RabbitMQ** y **Outbox Pattern**, además de **seguridad JWT/RS256** y **observabilidad con trace_id**.
