from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from sb_common.config import settings


_engine: Engine | None = None


def get_engine() -> Engine:
    global _engine
    if _engine is None:
        _engine = create_engine(settings.postgres_dsn, pool_pre_ping=True)
    return _engine
