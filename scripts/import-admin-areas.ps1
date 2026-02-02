param(
  [Parameter(Mandatory = $true)][string]$GeoJsonPath,
  [string]$Python = "F:/Mis Proyectos/SmartBuket Analytics/.venv/Scripts/python.exe"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $GeoJsonPath)) {
  throw "GeoJSON file not found: $GeoJsonPath"
}

# Requires SB_POSTGRES_DSN env var if not using default
& $Python "scripts/import_admin_areas.py" $GeoJsonPath
