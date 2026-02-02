# Eventos comerciales estándar (obligatorios cuando aplique)

Estos eventos viven dentro del envelope/contrato núcleo (schema-light) y, si está habilitado el modo estricto, dentro del envelope Prompt Maestro.

- Contrato core (legacy/minimal): `contracts/event-core.schema.json`
- Contrato Prompt Maestro (estricto): `contracts/event-prompt-maestro.schema.json`
Analytics **no valida** campos internos de `payload`, pero recomienda claves estables.

## Lista
- `feature.use` (payload: `feature_code`, opcional `value`)
- `paywall.view` (payload: `paywall_code`, opcional `trigger`)
- `premium.intent` (payload: `target_plan` o `target_app`)
- `limit.reached` (payload: `limit_code`, opcional `current`, `max`)
- `purchase.success` (payload: `product_sku`, `price`, `currency`, `billing_type`)

## Reglas
- `feature_code` debe ser estable en el tiempo.
- No enviar PII (email, teléfono, nombre).
- Los IDs siempre anonimizados (`anon_user_id`, `device_id_hash`).

