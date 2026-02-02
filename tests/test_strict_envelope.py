import importlib
import os
from uuid import uuid4


def _reload_parser(strict: bool):
    os.environ["SB_STRICT_ENVELOPE"] = "1" if strict else "0"

    import sb_common.config as config
    import sb_common.event_minimal as event_minimal

    importlib.reload(config)
    importlib.reload(event_minimal)
    return event_minimal.parse_minimal_event


def _base_doc():
    return {
        "app_uuid": str(uuid4()),
        "anon_user_id": "u_test",
        "device_id_hash": "d_test",
        "session_id": "s_test",
        "sdk_version": "1.0.0",
        "event_version": "1",
        "payload": {},
        "context": {},
    }


def test_strict_envelope_rejects_legacy_only():
    parse = _reload_parser(strict=True)
    doc = {
        **_base_doc(),
        "event_type": "geo.ping",
        "timestamp": "2020-01-01T00:00:00Z",
    }

    try:
        parse(doc)
        assert False, "expected rejection"
    except Exception as exc:
        assert "missing required envelope fields" in str(exc)


def test_strict_envelope_accepts_prompt_maestro_fields_without_legacy_aliases():
    parse = _reload_parser(strict=True)
    doc = {
        **_base_doc(),
        "event_name": "geo.ping",
        "occurred_at": "2020-01-01T00:00:00Z",
        "event_id": str(uuid4()),
        "trace_id": str(uuid4()),
        "producer": "pytest",
        "actor": "anonymous",
    }

    ev = parse(doc)
    assert ev.event_type == "geo.ping"
    assert ev.timestamp.isoformat().startswith("2020-01-01T00:00:00")


def test_non_strict_accepts_legacy_fields():
    parse = _reload_parser(strict=False)
    doc = {
        **_base_doc(),
        "event_type": "geo.ping",
        "timestamp": "2020-01-01T00:00:00Z",
    }

    ev = parse(doc)
    assert ev.event_type == "geo.ping"


def test_non_strict_accepts_prompt_maestro_aliases():
    parse = _reload_parser(strict=False)
    doc = {
        **_base_doc(),
        "event_name": "geo.ping",
        "occurred_at": "2020-01-01T00:00:00Z",
    }

    ev = parse(doc)
    assert ev.event_type == "geo.ping"
