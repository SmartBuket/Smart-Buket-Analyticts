# Runbook — DLQ creciendo

## Síntomas

- La cola `sb.events.dlq.q` crece.
- Se observan errores en el processor.

## Diagnóstico

1) Abrir RabbitMQ UI:

- `http://localhost:15672` (dev: `guest/guest`)

2) Revisar rate de publicaciones a DLQ y mirar mensajes:

- En la cola `sb.events.dlq.q` usar "Get messages".

3) Revisar logs del processor:

- `Get-Content .\scripts\logs\sb-processor.<RunId>.err.log -Wait`

## Causas comunes

- Payload inválido / faltan campos mínimos.
- Problemas de DB (locks, timeouts, migrations faltantes).
- Errores permanentes en reglas de negocio (por ejemplo, datos incoherentes).

## Acciones

- Si es error transitorio (DB/network):
  - El processor reintenta (hasta `SB_PROCESSOR_MAX_RETRIES`) antes de DLQ.
  - Verificar DB y latencia; después reprocesar manualmente DLQ.

- Si es error de contrato:
  - Corregir producer y/o relajar/ajustar validación (idealmente no).
  - En strict mode (`SB_STRICT_ENVELOPE=1`) el ingest debería rechazar antes de llegar a DLQ.

## Reprocesar DLQ (manual)

- Opción 1: copiar mensajes desde la UI y re-publicar a routing key original.
- Opción 2: construir un script de reproceso controlado (recomendado para prod).

## Prevención

- Alertas en `sb.events.dlq.q` depth.
- Trazabilidad: incluir `trace_id` y `event_id` en logs.
