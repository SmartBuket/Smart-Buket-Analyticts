from __future__ import annotations

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class Settings:
    postgres_dsn: str = os.getenv(
        "SB_POSTGRES_DSN",
        "postgresql+psycopg://sb:sb@localhost:15432/sb_analytics",
    )

    # Broker (PETS / Prompt Maestro): RabbitMQ topic exchange.
    rabbitmq_url: str = os.getenv("SB_RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
    rabbitmq_exchange: str = os.getenv("SB_RABBITMQ_EXCHANGE", "sb.events")

    # Consumer group id is used as a stable identifier for processor instances (also
    # helpful when evolving the materializations).
    processor_group_id: str = os.getenv("SB_PROCESSOR_GROUP_ID", "sb-processor")

    # Processor retry policy
    processor_max_retries: int = int(os.getenv("SB_PROCESSOR_MAX_RETRIES", "5"))
    processor_retry_base_seconds: float = float(os.getenv("SB_PROCESSOR_RETRY_BASE_SECONDS", "0.5"))
    processor_retry_max_seconds: float = float(os.getenv("SB_PROCESSOR_RETRY_MAX_SECONDS", "10"))

    # Governance: optional shared API key for HTTP APIs (ingest/query/reco).
    # If empty, services run in dev-open mode.
    api_key: str = os.getenv("SB_API_KEY", "")

    # Auth mode:
    # - open: no auth (dev)
    # - api_key: require SB_API_KEY
    # - jwt: require JWT RS256 (via JWKS)
    # - jwt_or_api_key: accept either (migration)
    auth_mode: str = os.getenv("SB_AUTH_MODE", "open").strip().lower()

    # Rate limiting (in-app). In production prefer API Gateway/Apigee.
    rate_limit_enabled: bool = os.getenv("SB_RATE_LIMIT_ENABLED", "0").strip() == "1"
    rate_limit_ingest_events: str = os.getenv("SB_RATE_LIMIT_INGEST_EVENTS", "120/60").strip()
    rate_limit_privacy: str = os.getenv("SB_RATE_LIMIT_PRIVACY", "30/60").strip()
    rate_limit_query: str = os.getenv("SB_RATE_LIMIT_QUERY", "300/60").strip()
    rate_limit_reco: str = os.getenv("SB_RATE_LIMIT_RECO", "120/60").strip()

    # Observability
    log_level: str = os.getenv("SB_LOG_LEVEL", "INFO").strip().upper()

    # Metrics
    metrics_enabled: bool = os.getenv("SB_METRICS_ENABLED", "1").strip() == "1"
    metrics_public: bool = os.getenv("SB_METRICS_PUBLIC", "0").strip() == "1"

    # Security (Prompt Maestro / PETS): JWT RS256 + JWKS.
    # If SB_JWKS_URL is set and an Authorization: Bearer <jwt> is provided, services can
    # validate JWTs. If unset, JWT validation is disabled.
    jwks_url: str = os.getenv("SB_JWKS_URL", "").strip()
    jwt_issuer: str = os.getenv("SB_JWT_ISSUER", "").strip()
    jwt_audience: str = os.getenv("SB_JWT_AUDIENCE", "").strip()
    rbac_enforce: bool = os.getenv("SB_RBAC_ENFORCE", "0").strip() == "1"

    # Envelope validation
    strict_envelope: bool = os.getenv("SB_STRICT_ENVELOPE", "0").strip() == "1"

    # Routing keys (topic exchange)
    topic_raw: str = os.getenv("SB_TOPIC_RAW", "sb.events.raw")
    topic_geo: str = os.getenv("SB_TOPIC_GEO", "sb.events.geo")
    topic_license: str = os.getenv("SB_TOPIC_LICENSE", "sb.events.license")
    topic_session: str = os.getenv("SB_TOPIC_SESSION", "sb.events.session")
    topic_screen: str = os.getenv("SB_TOPIC_SCREEN", "sb.events.screen")
    topic_ui: str = os.getenv("SB_TOPIC_UI", "sb.events.ui")
    topic_system: str = os.getenv("SB_TOPIC_SYSTEM", "sb.events.system")
    topic_dlq: str = os.getenv("SB_TOPIC_DLQ", "sb.events.dlq")

    h3_resolutions: tuple[int, ...] = tuple(
        int(x) for x in os.getenv("SB_H3_RES", "7,9,11").split(",") if x.strip()
    )


settings = Settings()
