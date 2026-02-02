from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from sqlalchemy import text

from sb_common.db import get_engine


@dataclass(frozen=True)
class Place:
    place_id: str
    name: str
    place_type: str
    geom_geojson: dict[str, Any]
    radius_m: float | None
    valid_from: datetime | None
    valid_to: datetime | None


def _maybe_dt(v: Any) -> datetime | None:
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception:
        return None


def load_geojson(path: Path) -> list[Place]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if doc.get("type") != "FeatureCollection":
        raise ValueError("GeoJSON must be a FeatureCollection")

    out: list[Place] = []
    for feat in doc.get("features", []):
        if feat.get("type") != "Feature":
            continue

        props = feat.get("properties") or {}
        geom = feat.get("geometry")
        if not geom:
            continue

        place_id = str(props.get("place_id", "")).strip()
        name = str(props.get("name", "")).strip()
        place_type = str(props.get("place_type", "")).strip()

        if not place_id or not name or not place_type:
            raise ValueError("properties.place_id, properties.name, properties.place_type are required")

        radius_m: float | None = None
        if props.get("radius_m") is not None:
            try:
                radius_m = float(props.get("radius_m"))
            except Exception:
                raise ValueError("properties.radius_m must be a number if provided")

        out.append(
            Place(
                place_id=place_id,
                name=name,
                place_type=place_type,
                geom_geojson=geom,
                radius_m=radius_m,
                valid_from=_maybe_dt(props.get("valid_from")),
                valid_to=_maybe_dt(props.get("valid_to")),
            )
        )

    return out


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: import_places.py <path_to_geojson>")
        return 2

    path = Path(sys.argv[1]).expanduser().resolve()
    places = load_geojson(path)

    insert_sql = text(
        """
        INSERT INTO places (place_id, name, place_type, geofence, valid_from, valid_to)
        VALUES (
          :place_id,
          :name,
          :place_type,
          CASE
                        WHEN (:radius_m)::double precision IS NULL THEN ST_SetSRID(ST_GeomFromGeoJSON(:geom), 4326)
            ELSE ST_Buffer(
              ST_SetSRID(ST_GeomFromGeoJSON(:geom), 4326)::geography,
                            (:radius_m)::double precision
            )::geometry
          END,
          :valid_from,
          :valid_to
        )
        ON CONFLICT (place_id)
        DO UPDATE SET
          name = EXCLUDED.name,
          place_type = EXCLUDED.place_type,
          geofence = EXCLUDED.geofence,
          valid_from = EXCLUDED.valid_from,
          valid_to = EXCLUDED.valid_to
        """
    )

    with get_engine().begin() as conn:
        for p in places:
            conn.execute(
                insert_sql,
                {
                    "place_id": p.place_id,
                    "name": p.name,
                    "place_type": p.place_type,
                    "geom": json.dumps(p.geom_geojson),
                    "radius_m": p.radius_m,
                    "valid_from": p.valid_from,
                    "valid_to": p.valid_to,
                },
            )

    print(f"imported/updated {len(places)} places")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
