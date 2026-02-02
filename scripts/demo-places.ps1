param(
  [string]$IngestBase = "http://localhost:8001",
  [string]$QueryBase  = "http://localhost:8002",
  [string]$RecoBase   = "http://localhost:8003",
  [string]$PlacesGeoJson = ".\\examples\\places.sample.geojson",
  [int]$WaitSeconds   = 6
)

$ErrorActionPreference = "Stop"

function To-IsoUtc([datetime]$dt) {
  return $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if (!(Test-Path $PlacesGeoJson)) {
  throw "Places GeoJSON not found: $PlacesGeoJson"
}

Write-Host "Importing places from: $PlacesGeoJson" -ForegroundColor Cyan
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\import-places.ps1 -GeoJsonPath $PlacesGeoJson
if ($LASTEXITCODE -ne 0) {
  throw "import-places failed with exit code $LASTEXITCODE"
}

Write-Host "Running demo flow (ingest -> processor -> query/offers)..." -ForegroundColor Cyan
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo-flow.ps1 -IngestBase $IngestBase -QueryBase $QueryBase -RecoBase $RecoBase -WaitSeconds $WaitSeconds

# Same app_uuid as demo-flow.ps1
$appUuid = "b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7"
$placeId = "demo_sd_poly"

# Query window: last 2 hours (same logic as demo-flow)
$now = [datetime]::UtcNow
$hour0 = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, 0, 0, [DateTimeKind]::Utc)
$hour1 = $hour0.AddHours(-1)
$start = (To-IsoUtc $hour1.AddMinutes(-1))
$end = (To-IsoUtc $hour0.AddHours(1))

Write-Host "List places (catalog)" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/places" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "DAH by place_id=$placeId" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/metrics/active-devices-hourly?start=$start&end=$end&app_uuid=$appUuid&place_id=$placeId" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "UAH by place_id=$placeId" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/metrics/active-users-hourly?start=$start&end=$end&app_uuid=$appUuid&place_id=$placeId" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Peak hour (devices) by place_id=$placeId" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/metrics/peak-hour?start=$start&end=$end&app_uuid=$appUuid&place_id=$placeId&dimension=devices" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Recurrence (devices) by place_id=$placeId" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/places/$placeId/metrics/recurrence?start=$start&end=$end&dimension=devices" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Dwell estimate (devices) by place_id=$placeId" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/places/$placeId/metrics/dwell?start=$start&end=$end&dimension=devices" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Done." -ForegroundColor Green
