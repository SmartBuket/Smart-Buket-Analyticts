from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.engine import Connection


_OPT_OUT_SQL = text(
    """
    SELECT 1
    FROM opt_out
    WHERE app_uuid = CAST(:app_uuid AS uuid)
      AND anon_user_id = :anon_user_id
    LIMIT 1
    """
)


def is_opted_out(conn: Connection, *, app_uuid: str, anon_user_id: str) -> bool:
    row = conn.execute(
        _OPT_OUT_SQL,
        {"app_uuid": str(app_uuid), "anon_user_id": str(anon_user_id)},
    ).first()
    return row is not None
