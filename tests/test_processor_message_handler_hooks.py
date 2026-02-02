import importlib.util
import json
from pathlib import Path
import sys


def _load_module(name: str, rel_path: str):
    root = Path(__file__).resolve().parents[1]
    path = root / rel_path
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def test_processor_handler_acks_when_already_processed():
    mod = _load_module(
        "sb_processor_worker",
        "services/processor/app/worker.py",
    )

    assert hasattr(mod, "make_message_handler")

    class _FirstResult:
        def __init__(self, first_value):
            self._first_value = first_value

        def first(self):
            return self._first_value

    class _FakeConn:
        def execute(self, sql, params=None):
            sql_s = str(sql).lower()
            if "insert into processed_events" in sql_s:
                # Simulate dedupe hit: row already exists -> RETURNING yields nothing.
                return _FirstResult(None)
            raise AssertionError(f"unexpected execute: {sql_s}")

    class _Begin:
        def __init__(self, conn):
            self._conn = conn

        def __enter__(self):
            return self._conn

        def __exit__(self, exc_type, exc, tb):
            return False

    class _FakeEngine:
        def __init__(self, conn):
            self._conn = conn

        def begin(self):
            return _Begin(self._conn)

    class _FakeCh:
        def __init__(self):
            self.acked = 0
            self.nacked = 0

        def basic_ack(self, delivery_tag):
            self.acked += 1

        def basic_nack(self, delivery_tag, requeue):
            self.nacked += 1

    class _FakeChannel:
        def basic_publish(self, *args, **kwargs):
            raise AssertionError("should not publish in this test")

    class _Method:
        delivery_tag = 123
        routing_key = "sb.events.geo"

    class _Props:
        headers = {}

    engine = _FakeEngine(_FakeConn())
    rabbit_channel = _FakeChannel()
    opted_out_cache = set()

    handler = mod.make_message_handler(
        engine=engine,
        channel=rabbit_channel,
        consumer_id="sb-processor",
        opted_out_cache=opted_out_cache,
    )

    ch = _FakeCh()
    body = json.dumps(
        {
            "app_uuid": "app",
            "event_id": "evt",
            "anon_user_id": "u",
            "event_name": "geo.ping",
        }
    ).encode("utf-8")

    handler(ch, _Method(), _Props(), body)

    # Critical: even if already processed, we must ACK so the message doesn't redeliver forever.
    assert ch.acked == 1
    assert ch.nacked == 0


def test_processor_handler_acks_and_caches_when_opted_out():
    mod = _load_module(
        "sb_processor_worker_optout",
        "services/processor/app/worker.py",
    )

    class _FirstResult:
        def __init__(self, first_value):
            self._first_value = first_value

        def first(self):
            return self._first_value

    class _FakeConn:
        def execute(self, sql, params=None):
            sql_s = str(sql).lower()
            if "insert into processed_events" in sql_s:
                # First time seeing event -> allowed to process.
                return _FirstResult((1,))
            if "from opt_out" in sql_s:
                # Simulate opt-out exists.
                return _FirstResult((1,))
            raise AssertionError(f"unexpected execute: {sql_s}")

    class _Begin:
        def __init__(self, conn):
            self._conn = conn

        def __enter__(self):
            return self._conn

        def __exit__(self, exc_type, exc, tb):
            return False

    class _FakeEngine:
        def __init__(self, conn):
            self._conn = conn

        def begin(self):
            return _Begin(self._conn)

    class _FakeCh:
        def __init__(self):
            self.acked = 0

        def basic_ack(self, delivery_tag):
            self.acked += 1

        def basic_nack(self, delivery_tag, requeue):
            raise AssertionError("should not nack in this test")

    class _FakeChannel:
        def basic_publish(self, *args, **kwargs):
            raise AssertionError("should not publish in this test")

    class _Method:
        delivery_tag = 456
        routing_key = "sb.events.geo"

    class _Props:
        headers = {}

    engine = _FakeEngine(_FakeConn())
    rabbit_channel = _FakeChannel()
    opted_out_cache = set()

    handler = mod.make_message_handler(
        engine=engine,
        channel=rabbit_channel,
        consumer_id="sb-processor",
        opted_out_cache=opted_out_cache,
    )

    ch = _FakeCh()
    doc = {
        "app_uuid": "app-1",
        "event_id": "evt-1",
        "anon_user_id": "u-1",
        "event_name": "geo.ping",
    }
    handler(ch, _Method(), _Props(), json.dumps(doc).encode("utf-8"))

    assert ch.acked == 1
    assert ("app-1", "u-1") in opted_out_cache
