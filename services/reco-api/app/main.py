from __future__ import annotations

from datetime import datetime, timedelta
from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy import text

from sb_common.auth import require_api_key, require_scopes
from sb_common.config import settings
from sb_common.db import get_engine
from sb_common.hardening import setup_hardening
from sb_common.metrics import add_metrics
from sb_common.observability import setup_observability
from sb_common.rate_limit import RateLimitMiddleware, Rule, parse_rate


app = FastAPI(
    title="SmartBuket Analytics Offers API",
    version="0.1.0",
    dependencies=[Depends(require_api_key)],
)

setup_observability(app, log_level=settings.log_level)
setup_hardening(app)

if settings.metrics_enabled:
    add_metrics(app, service="reco-api", public=settings.metrics_public)

app.add_middleware(
    RateLimitMiddleware,
    service="reco-api",
    enabled=settings.rate_limit_enabled,
    rules=[
        Rule("GET", "/v1/offers", parse_rate(settings.rate_limit_reco)),
    ],
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get(
    "/v1/offers",
    dependencies=[Depends(require_scopes("sb.reco.read"))],
)
def offers(anon_user_id: str, app_uuid: str | None = None) -> dict:
    # Privacy: only aggregated/scored outputs; no raw event echo.
    lookback = datetime.utcnow() - timedelta(days=30)

    engine = get_engine()

    with engine.connect() as conn:
        if app_uuid:
            opted = conn.execute(
                text(
                    "SELECT 1 FROM opt_out WHERE app_uuid = CAST(:a AS uuid) AND anon_user_id = :u LIMIT 1"
                ),
                {"a": app_uuid, "u": anon_user_id},
            ).first()
        else:
            opted = conn.execute(
                text("SELECT 1 FROM opt_out WHERE anon_user_id = :u LIMIT 1"),
                {"u": anon_user_id},
            ).first()
        if opted:
            return {"anon_user_id": anon_user_id, "offers": []}

        # Signals in last 30d
        where = ["anon_user_id = :u", "event_ts >= :lb"]
        params: dict[str, object] = {"u": anon_user_id, "lb": lookback}
        if app_uuid:
            where.append("app_uuid = CAST(:a AS uuid)")
            params["a"] = app_uuid

        signals = conn.execute(
            text(
                f"""
                SELECT event_type, COUNT(*) AS c
                FROM raw_events
                WHERE {' AND '.join(where)}
                  AND event_type IN ('paywall.view', 'premium.intent', 'limit.reached', 'purchase.success')
                GROUP BY event_type
                """
            ),
            params,
        ).mappings().all()

        signal_counts = {r["event_type"]: int(r["c"]) for r in signals}

        # License state snapshot (if any)
        lic_where = ["anon_user_id = :u"]
        lic_params: dict[str, object] = {"u": anon_user_id}
        if app_uuid:
            lic_where.append("app_uuid = CAST(:a AS uuid)")
            lic_params["a"] = app_uuid

        licenses = conn.execute(
            text(
                f"""
                SELECT app_uuid::text AS app_uuid, plan_type, license_status, expires_at
                FROM license_state
                WHERE {' AND '.join(lic_where)}
                """
            ),
            lic_params,
        ).mappings().all()

    paywall = signal_counts.get("paywall.view", 0)
    intent = signal_counts.get("premium.intent", 0)
    limit_reached = signal_counts.get("limit.reached", 0)
    purchase = signal_counts.get("purchase.success", 0)

    # Level 1 deterministic rules (MVP)
    offers_out: list[dict] = []

    # Upsell: high friction + intent, no purchase
    if purchase == 0 and (intent >= 1 or (paywall + limit_reached) >= 3):
        offers_out.append(
            {
                "type": "upgrade",
                "message": "Desbloquea funciones premium para eliminar límites.",
                "reason": {
                    "explainable": True,
                    "signals": {
                        "paywall.view_30d": paywall,
                        "limit.reached_30d": limit_reached,
                        "premium.intent_30d": intent,
                    },
                },
                "valid_until": (datetime.utcnow() + timedelta(days=7)).isoformat() + "Z",
            }
        )

    # Renewal: license expired / expiring soon
    for lic in licenses:
        status = (lic.get("license_status") or "").lower()
        exp = lic.get("expires_at")
        if status in {"expired", "canceled"}:
            offers_out.append(
                {
                    "type": "plan",
                    "message": "Renueva tu plan para mantener acceso premium.",
                    "reason": {
                        "explainable": True,
                        "license": {
                            "app_uuid": lic.get("app_uuid"),
                            "plan_type": lic.get("plan_type"),
                            "license_status": lic.get("license_status"),
                        },
                    },
                    "valid_until": (datetime.utcnow() + timedelta(days=14)).isoformat() + "Z",
                }
            )
        elif exp is not None:
            # If expiring within 7d
            try:
                if isinstance(exp, str):
                    exp_dt = datetime.fromisoformat(exp.replace("Z", "+00:00"))
                else:
                    exp_dt = exp
                if exp_dt and exp_dt <= datetime.utcnow().replace(tzinfo=exp_dt.tzinfo) + timedelta(days=7):
                    offers_out.append(
                        {
                            "type": "plan",
                            "message": "Tu plan está por vencer: renueva hoy.",
                            "reason": {"explainable": True, "expires_at": str(exp)},
                            "valid_until": (datetime.utcnow() + timedelta(days=7)).isoformat() + "Z",
                        }
                    )
            except Exception:
                pass

    # Limit output to Top offers (simple ordering)
    offers_out = offers_out[:5]

    return {"anon_user_id": anon_user_id, "offers": offers_out}
