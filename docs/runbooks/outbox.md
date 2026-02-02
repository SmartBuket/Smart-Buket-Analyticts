# Runbook — Outbox atascado

## Síntomas

- `raw_events` crece pero downstream no se actualiza.
- RabbitMQ tiene poca actividad.
- `outbox_events` con muchos registros `status='pending'` o `failed`.

## Diagnóstico rápido

1) Ver logs del publicador:

- `Get-Content .\scripts\logs\sb-outbox.<RunId>.err.log -Wait`

2) Ver estado de outbox en DB (pgAdmin o psql):

- Pending:
  - `SELECT count(*) FROM outbox_events WHERE status='pending';`
- Failed:
  - `SELECT count(*) FROM outbox_events WHERE status='failed';`
- Último error:
  - `SELECT id, retries, last_error, next_attempt_at FROM outbox_events WHERE status!='sent' ORDER BY id DESC LIMIT 20;`

3) Verificar conectividad a RabbitMQ:

- UI: `http://localhost:15672`

## Acciones

- Si hay errores de conexión (AMQP):
  - Verificar `SB_RABBITMQ_URL`.
  - Verificar que el contenedor `sb-rabbitmq` esté up.
  - Reiniciar el publicador: `scripts/restart-all.cmd` (o volver a correr `scripts/run-all.ps1`).

- Si el publicador está vivo pero no avanza:
  - Revisar que `outbox_events.next_attempt_at <= now()` para los pendientes.
  - Si quedó un lote con `next_attempt_at` muy en el futuro, corregir manualmente (solo si entiendes el impacto):
    - `UPDATE outbox_events SET next_attempt_at = now() WHERE status='pending' AND next_attempt_at > now() + interval '10 minutes';`

## Prevención

- Mantener el publicador como Deployment con liveness/readiness.
- Alertas: `outbox_events pending/failed` creciendo sostenido.
