# Paso 11 — Cobertura de eventos y módulos P2

Este documento describe familias de eventos "P2" y cómo quedan enrutadas en el bus (RabbitMQ topic exchange `sb.events`) para permitir evolucionar materializaciones/consumidores sin acoplar ingest.

## Familias P2 (naming)

- `session.*`
  - Ejemplos: `session.start`, `session.end`, `session.heartbeat`
- `screen.*`
  - Ejemplos: `screen.view`, `screen.focus`, `screen.blur`
- `ui.*`
  - Ejemplos: `ui.click`, `ui.submit`, `ui.scroll`
- `system.*`
  - Ejemplos: `system.crash`, `system.error`, `system.performance`

Estas familias son opcionales: pueden enviarse como crudo (raw) aun si no hay consumidores.

## Routing keys (RabbitMQ)

Ingest siempre registra en outbox el routing key `sb.events.raw`.

Además, si `event_name`/`event_type` cae en una familia P2, también se stagea una copia al routing key dedicado:

- `session.*` → `sb.events.session`
- `screen.*` → `sb.events.screen`
- `ui.*` → `sb.events.ui`
- `system.*` → `sb.events.system`

Geo y licensing permanecen igual:

- `geo.ping` → `sb.events.geo`
- `license.*` → `sb.events.license`

## Colas declaradas

El publicador del outbox declara y bindea colas durables (aunque hoy no haya consumers para P2):

- `sb.events.raw.q`
- `sb.events.geo.q`
- `sb.events.license.q`
- `sb.events.session.q`
- `sb.events.screen.q`
- `sb.events.ui.q`
- `sb.events.system.q`
- `sb.events.dlq.q`

## Política de protección (colas sin consumer)

Para evitar crecimiento infinito si no existen consumidores, el script `scripts/run-all.ps1` aplica una policy sobre:

- `sb.events.raw.q`
- `sb.events.session.q`
- `sb.events.screen.q`
- `sb.events.ui.q`
- `sb.events.system.q`

con:

- TTL: 24h
- Max length: 100k
- Overflow: `drop-head`

## Siguiente paso (cuando aplique)

- Materializar consumidores P2 (workers) según producto.
- Definir agregados/feature stores específicos (engagement, funnels, crash rate, etc.).
