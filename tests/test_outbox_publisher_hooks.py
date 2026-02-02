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


def test_outbox_publisher_exposes_atomic_locking_hook():
    mod = _load_module(
        "sb_outbox_publisher_worker",
        "services/outbox-publisher/app/worker.py",
    )

    assert hasattr(mod, "build_poll_sql")
    assert hasattr(mod, "lock_outbox_batch")

    class _FakeResult:
        def __init__(self, rows):
            self._rows = rows

        def mappings(self):
            return self

        def all(self):
            return self._rows

    class _FakeTx:
        def __init__(self):
            self.last_sql = None
            self.last_params = None

        def execute(self, sql, params):
            self.last_sql = str(sql)
            self.last_params = params
            return _FakeResult(
                [
                    {
                        "id": 1,
                        "routing_key": "sb.events.geo",
                        "payload": json.loads('{"hello":"world"}'),
                        "retries": 0,
                    }
                ]
            )

    tx = _FakeTx()
    rows = mod.lock_outbox_batch(tx, limit=7)

    assert tx.last_params == {"limit": 7}
    assert isinstance(rows, list) and rows and rows[0]["id"] == 1

    # Guardrail: the query must UPDATE locked_at in the same statement
    # (prevents duplicate publishing with multiple publisher instances).
    sql = tx.last_sql.lower()
    assert "update outbox_events" in sql
    assert "set locked_at" in sql
    assert "returning" in sql
