# Runbook — RabbitMQ / broker

## Checks

- UI: `http://localhost:15672` (dev: `guest/guest`)
- Queues esperadas (mínimo):
  - `sb.events.geo.q`, `sb.events.license.q`, `sb.events.raw.q`, `sb.events.dlq.q`
  - P2: `sb.events.session.q`, `sb.events.screen.q`, `sb.events.ui.q`, `sb.events.system.q`

## Policy de protección (colas sin consumer)

Se aplica desde `scripts/run-all.ps1`:

- TTL 24h
- max-length 100k
- overflow drop-head

Aplica a `raw` y colas P2 que típicamente no tienen consumer en MVP.

## Problemas frecuentes

- "Management API not ready":
  - Esperar unos segundos; `run-all.ps1` reintenta.

- Mensajes acumulados en `raw`/P2:
  - Esperado si no hay consumer; la policy evita crecimiento sin límite.

- Mensajes acumulados en `geo`/`license`:
  - Indica processor caído o lento.

## Acciones

- Verificar proceso `sb-processor` en `scripts/status.ps1`.
- Reiniciar todo: `scripts/stop-all.ps1` y `scripts/run-all.ps1`.
