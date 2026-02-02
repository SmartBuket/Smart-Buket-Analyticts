# Zonificación administrativa (país/provincia/municipio/sector)

## Qué se implementa
- Catálogo de polígonos administrativos en PostGIS (`admin_areas`).
- Enriquecimiento en `processor`: al consumir `geo.ping`, busca el polígono que contiene el punto y guarda:
  - `admin_country_code`
  - `admin_province_code`
  - `admin_municipality_code`
  - `admin_sector_code`

## Fuente de datos
No se incluyen boundaries en el repo (deben ser provistos por tu organización).

## Formato de importación (GeoJSON)
Un archivo GeoJSON con `FeatureCollection` donde cada `Feature` tenga:

- `properties.level`: `country|province|municipality|sector`
- `properties.code`: código estable (string)
- `properties.name`: nombre
- `properties.parent_code`: opcional (para jerarquía)

La geometría debe ser `Polygon` o `MultiPolygon` en WGS84 (EPSG:4326).

## Importar
Usa el script `scripts/import-admin-areas.ps1` (que llama a `scripts/import_admin_areas.py`).

## Degradación por precisión
- Si `accuracy_m` es alta (coarse), el processor guarda solo niveles macro (country/province) y deja `municipality/sector` en null.

