from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sqlalchemy import text

from sb_common.db import get_engine


@dataclass(frozen=True)
class AdminArea:
    level: str
    code: str
    name: str
    parent_code: str | None
    geom_geojson: dict[str, Any]


ALLOWED_LEVELS = {"country", "province", "municipality", "sector"}


def load_geojson(path: Path) -> list[AdminArea]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if doc.get("type") != "FeatureCollection":
        raise ValueError("GeoJSON must be a FeatureCollection")

    out: list[AdminArea] = []
    for feat in doc.get("features", []):
        if feat.get("type") != "Feature":
            continue
        props = feat.get("properties") or {}
        geom = feat.get("geometry")
        if not geom:
            continue

        level = str(props.get("level", "")).strip()
        code = str(props.get("code", "")).strip()
        name = str(props.get("name", "")).strip()
        parent_code = props.get("parent_code")
        parent_code = str(parent_code).strip() if parent_code is not None else None

        if level not in ALLOWED_LEVELS:
            raise ValueError(f"invalid level: {level}")
        if not code or not name:
            raise ValueError("properties.code and properties.name are required")

        out.append(
            AdminArea(
                level=level,
                code=code,
                name=name,
                parent_code=parent_code,
                geom_geojson=geom,
            )
        )

    return out


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: import_admin_areas.py <path_to_geojson>")
        return 2

    path = Path(sys.argv[1]).expanduser().resolve()
    areas = load_geojson(path)

    engine = get_engine()

    insert_sql = text(
        """
        INSERT INTO admin_areas (level, code, name, parent_code, geom)
        VALUES (:level, :code, :name, :parent_code, ST_SetSRID(ST_GeomFromGeoJSON(:geom), 4326))
        ON CONFLICT (level, code)
        DO UPDATE SET
          name = EXCLUDED.name,
          parent_code = EXCLUDED.parent_code,
          geom = EXCLUDED.geom
        """
    )

    with engine.begin() as conn:
        for a in areas:
            conn.execute(
                insert_sql,
                {
                    "level": a.level,
                    "code": a.code,
                    "name": a.name,
                    "parent_code": a.parent_code,
                    "geom": json.dumps(a.geom_geojson),
                },
            )

    print(f"imported/updated {len(areas)} admin areas")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
