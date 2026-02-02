from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Any

import orjson
import pika
from sqlalchemy import text

from sb_common.config import settings
from sb_common.db import get_engine
from sb_common.schema import ensure_outbox


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _backoff_seconds(retries: int) -> int:
    # Exponential backoff with cap.
    # 0->2s, 1->4s, 2->8s, ... capped to 5 minutes.
    return min(300, 2 ** (retries + 1))


def _connect() -> pika.BlockingConnection:
    params = pika.URLParameters(settings.rabbitmq_url)
    return pika.BlockingConnection(params)


def _ensure_topology(ch: pika.adapters.blocking_connection.BlockingChannel) -> None:
    ch.exchange_declare(exchange=settings.rabbitmq_exchange, exchange_type="topic", durable=True)

    bindings = [
        ("sb.events.geo.q", settings.topic_geo),
        ("sb.events.license.q", settings.topic_license),
        ("sb.events.session.q", settings.topic_session),
        ("sb.events.screen.q", settings.topic_screen),
        ("sb.events.ui.q", settings.topic_ui),
        ("sb.events.system.q", settings.topic_system),
        ("sb.events.dlq.q", settings.topic_dlq),
        ("sb.events.raw.q", settings.topic_raw),
    ]

    for queue, routing_key in bindings:
        ch.queue_declare(queue=queue, durable=True)
        ch.queue_bind(queue=queue, exchange=settings.rabbitmq_exchange, routing_key=routing_key)


def publish(routing_key: str, payload: dict[str, Any]) -> None:
    body = orjson.dumps(payload)

    conn = _connect()
    try:
        ch = conn.channel()
        _ensure_topology(ch)
        props = pika.BasicProperties(content_type="application/json", delivery_mode=2)
        ch.basic_publish(
            exchange=settings.rabbitmq_exchange,
            routing_key=routing_key,
            body=body,
            properties=props,
        )
    finally:
        try:
            conn.close()
        except Exception:
            pass


# --- Test hooks ---

def build_poll_sql() -> Any:
    """Build the polling SQL used by the publisher.

    The important property is that it atomically locks a batch by updating
    `locked_at` in the same statement that selects rows.
    """

    return text(
        """
        WITH cte AS (
          SELECT id
          FROM outbox_events
          WHERE status = 'pending'
            AND next_attempt_at <= now()
            AND (
              locked_at IS NULL
              OR locked_at < (now() - interval '5 minutes')
            )
          ORDER BY id
          FOR UPDATE SKIP LOCKED
          LIMIT :limit
        ), locked AS (
          UPDATE outbox_events o
          SET locked_at = now()
          FROM cte
          WHERE o.id = cte.id
          RETURNING o.id, o.routing_key, o.payload, o.retries
        )
        SELECT * FROM locked
        """
    )


def lock_outbox_batch(tx: Any, *, limit: int) -> list[dict[str, Any]]:
    rows = tx.execute(build_poll_sql(), {"limit": int(limit)}).mappings().all()
    return [dict(r) for r in rows]


def main() -> None:
    engine = get_engine()
    ensure_outbox(engine)

    mark_sent = text("UPDATE outbox_events SET status='sent', locked_at=NULL WHERE id = :id")
    mark_failed = text(
        """
        UPDATE outbox_events
        SET retries = retries + 1,
            last_error = :err,
            next_attempt_at = :next_attempt_at,
            locked_at = NULL,
            status = CASE WHEN retries + 1 >= :max_retries THEN 'failed' ELSE 'pending' END
        WHERE id = :id
        """
    )

    max_retries = 10
    batch_size = 50

    while True:
        with engine.begin() as tx:
            rows = lock_outbox_batch(tx, limit=batch_size)

        processed = 0
        for r in rows:
            outbox_id = int(r["id"])
            routing_key = str(r["routing_key"])
            retries = int(r["retries"])
            payload = r["payload"]

            try:
                publish(routing_key, payload)
                with engine.begin() as tx:
                    tx.execute(mark_sent, {"id": outbox_id})
                processed += 1
            except Exception as exc:
                next_ts = _utcnow() + timedelta(seconds=_backoff_seconds(retries))
                with engine.begin() as tx:
                    tx.execute(
                        mark_failed,
                        {
                            "id": outbox_id,
                            "err": f"{type(exc).__name__}: {exc}",
                            "next_attempt_at": next_ts,
                            "max_retries": max_retries,
                        },
                    )

        if processed == 0:
            time.sleep(1.0)


if __name__ == "__main__":
    main()
