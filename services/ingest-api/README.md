# ingest-api

Recibe eventos (schema-light), valida **solo** el contrato mínimo, guarda crudo y deja el envío al bus vía **Outbox Pattern**.

## Run
- `pip install -r requirements.txt`
- `uvicorn app.main:app --reload --port 8001`

## Endpoints
- `POST /v1/events` (batch)

Env:
- `SB_POSTGRES_DSN`
- `SB_RABBITMQ_URL`
- `SB_RABBITMQ_EXCHANGE` (opcional; default `sb.events`)
