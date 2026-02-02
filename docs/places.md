# Places (zonificación funcional)

## Qué es
Un *Place* es una zona funcional (plaza comercial, estadio, campus, parque industrial, evento temporal) representada como un geofence en PostGIS.

El `processor` intenta asignar `place_id` a cada `geo.ping` con un `ST_Contains` y lo guarda en los agregados horarios.

## Tabla
- `places(place_id, name, place_type, geofence, valid_from, valid_to)`

## Formato de importación (GeoJSON)
Archivo `FeatureCollection`.

Cada `Feature` debe tener:
- `properties.place_id`: string estable
- `properties.name`: nombre
- `properties.place_type`: tipo (ej. `mall|stadium|campus|industrial|event`)
- `properties.valid_from` (opcional): ISO-8601
- `properties.valid_to` (opcional): ISO-8601

### Geometría soportada
- `Polygon` o `MultiPolygon` en WGS84 (EPSG:4326)

Opcional (radio):
- `Point` en EPSG:4326 + `properties.radius_m` (número). El import lo convierte a un buffer circular.

## Importar
- PowerShell:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\import-places.ps1 -GeoJsonPath .\places.geojson`

## Ejemplo incluido
- Archivo: `examples/places.sample.geojson`
- Demo (importa + corre flujo + consulta métricas por place):
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo-places.ps1`

## Validación rápida
En Postgres:
- `SELECT place_id, name, place_type FROM places ORDER BY place_id;`

Luego, al correr el flujo (`demo-flow.ps1`), las filas en `device_hourly_presence` / `user_hourly_presence` deberían mostrar `place_id` cuando el punto cae dentro del geofence.
