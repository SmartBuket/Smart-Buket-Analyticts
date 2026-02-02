# Broker, routing keys y claves

## Objetivo
Mantener desacoplamiento total (apps no conocen Analytics internamente) y permitir escalabilidad a millones de eventos/día.

## Broker (PETS)

- RabbitMQ (exchange tipo `topic`, durable)
- Exchange por defecto: `sb.events`

## Routing keys sugeridos

- `sb.events.raw` — todos los eventos (núcleo), schema-light
- `sb.events.geo` — opcional: mirror/filtrado de `geo.ping` para procesamiento geo intensivo
- `sb.events.license` — eventos del Generador de Licencias
- `sb.events.dlq` — dead-letter (errores de parsing/validación mínima)

### DLQ (payload)
El `services/processor` publica a `sb.events.dlq` cuando no puede decodificar JSON o falla la validación mínima.

Campos principales:
- `failed_at`: timestamp UTC
- `reason`: `json_decode|invalid_document_type|minimal_event`
- `source`: `{topic, partition, offset}`
- `payload.raw_value_b64`: bytes originales (base64)
- `payload.decoded`: documento decodificado (si existió)
- `error`: `{type, message}`

## Clave de partición (recomendación)

- Primaria: `app_uuid`
- Secundaria (cuando aplique): `device_id_hash` (mantiene orden relativo por dispositivo)

Regla práctica:

- Para `geo.ping` y `session.*`: rutear por `app_uuid` (y opcionalmente incluir `device_id_hash` en headers o payload si se necesita orden relativo por dispositivo).

## Idempotencia
- Analytics debe tolerar reintentos.
- En agregados horarios aplicar dedupe por `(app_uuid, hour_bucket, device_id_hash)` y `(app_uuid, hour_bucket, anon_user_id)`.

