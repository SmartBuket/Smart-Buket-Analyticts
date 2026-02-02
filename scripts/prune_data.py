from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import sys

from sqlalchemy import text

from sb_common.config import settings
from sb_common.db import get_engine


@dataclass(frozen=True)
class PruneResult:
    raw_events_deleted: int
    device_presence_deleted: int
    user_presence_deleted: int
    customer_360_deleted: int


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def prune(*, raw_events_older_than_days: int, presence_older_than_days: int, prune_customer_360: bool, dry_run: bool) -> PruneResult:
    if raw_events_older_than_days < 0 or presence_older_than_days < 0:
        raise ValueError("days must be >= 0")

    raw_cutoff = _utc_now() - timedelta(days=raw_events_older_than_days)
    presence_cutoff = _utc_now() - timedelta(days=presence_older_than_days)

    delete_raw = text(
        """
        DELETE FROM raw_events
        WHERE event_ts < :cutoff
        """
    )

    delete_device = text(
        """
        DELETE FROM device_hourly_presence
        WHERE hour_bucket < :cutoff
        """
    )

    delete_user = text(
        """
        DELETE FROM user_hourly_presence
        WHERE hour_bucket < :cutoff
        """
    )

    delete_c360 = text(
        """
        DELETE FROM customer_360
        WHERE last_seen_at < :cutoff
        """
    )

    engine = get_engine()

    # Explicit transaction so dry-run can always rollback cleanly.
    with engine.connect() as conn:
        trans = conn.begin()
        try:
            raw_deleted = int(conn.execute(delete_raw, {"cutoff": raw_cutoff}).rowcount or 0)
            dev_deleted = int(conn.execute(delete_device, {"cutoff": presence_cutoff}).rowcount or 0)
            usr_deleted = int(conn.execute(delete_user, {"cutoff": presence_cutoff}).rowcount or 0)

            c360_deleted = 0
            if prune_customer_360:
                c360_deleted = int(conn.execute(delete_c360, {"cutoff": presence_cutoff}).rowcount or 0)

            if dry_run:
                trans.rollback()
            else:
                trans.commit()
        except Exception:
            trans.rollback()
            raise

    return PruneResult(
        raw_events_deleted=raw_deleted,
        device_presence_deleted=dev_deleted,
        user_presence_deleted=usr_deleted,
        customer_360_deleted=c360_deleted,
    )


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Prune Postgres data by retention windows.")
    p.add_argument(
        "--raw-days",
        type=int,
        default=90,
        help="Delete raw_events older than this many days (default: 90).",
    )
    p.add_argument(
        "--presence-days",
        type=int,
        default=730,
        help="Delete hourly presence rows older than this many days (default: 730 ~= 24 months).",
    )
    p.add_argument(
        "--prune-customer-360",
        action="store_true",
        help="Also delete customer_360 rows with last_seen_at older than presence cutoff.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute delete counts but rollback the transaction.",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        r = prune(
            raw_events_older_than_days=int(args.raw_days),
            presence_older_than_days=int(args.presence_days),
            prune_customer_360=bool(args.prune_customer_360),
            dry_run=bool(args.dry_run),
        )
    except Exception as exc:
        print(f"prune_data: error: {exc}", file=sys.stderr)
        return 2

    mode = "DRY_RUN" if args.dry_run else "APPLIED"
    now = _utc_now().isoformat().replace("+00:00", "Z")

    print(f"prune_data: {mode} at {now}")
    print("dsn: (hidden)")
    print(f"raw_events_deleted: {r.raw_events_deleted}")
    print(f"device_hourly_presence_deleted: {r.device_presence_deleted}")
    print(f"user_hourly_presence_deleted: {r.user_presence_deleted}")
    if args.prune_customer_360:
        print(f"customer_360_deleted: {r.customer_360_deleted}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
