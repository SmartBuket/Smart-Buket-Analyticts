# reco-api

Offers API basada en Customer 360 (reglas determinísticas en nivel 1).

## Run
- `pip install -r requirements.txt`
- `uvicorn app.main:app --reload --port 8003`

## Endpoint
- `GET /v1/offers?anon_user_id=...`
