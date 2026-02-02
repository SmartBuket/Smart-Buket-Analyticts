# Runbook — Security (Auth/RBAC) y rate limiting

## Auth modes

- `SB_AUTH_MODE=open` (dev)
- `SB_AUTH_MODE=api_key` (requiere `SB_API_KEY`)
- `SB_AUTH_MODE=jwt` (requiere `SB_JWKS_URL`, y valida RS256)
- `SB_AUTH_MODE=jwt_or_api_key` (migración)

## RBAC

- `SB_RBAC_ENFORCE=1` activa chequeo de scopes.

## Rate limiting

- `SB_RATE_LIMIT_ENABLED=1` activa el limitador in-app.
- Ajustes por servicio (ej):
  - `SB_RATE_LIMIT_INGEST_EVENTS=120/60`

## Síntomas

- 401/403 en endpoints:
  - Revisar `SB_AUTH_MODE`, token/API key y scopes.

- 429 Too Many Requests:
  - Revisar reglas y si es un burst esperado.

## Acciones

- Para prod: mover rate limiting y validación JWT al perímetro (API Gateway/Apigee) y dejar el in-app como defensa adicional.
