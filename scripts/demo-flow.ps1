param(
  [string]$IngestBase = "http://localhost:8001",
  [string]$QueryBase  = "http://localhost:8002",
  [string]$RecoBase   = "http://localhost:8003",
  [int]$WaitSeconds   = 6,
  [switch]$FreshIds
)

$ErrorActionPreference = "Stop"

function To-IsoUtc([datetime]$dt) {
  return $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Deterministic demo IDs (no PII)
$appUuid      = "b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7"
$anonUserId   = "u_demo_4f1c9b2d9a9c1f0d0a0b3c_demo"
$deviceHash   = "d_demo_aa93c0f1b1d6c2_demo"
$sessionHash  = "s_demo_2c9aa1c0d3_demo"
$sdkVersion   = "1.0.0"
$eventVersion = "1"

# Prompt Maestro envelope fields
$traceId = "11111111-1111-1111-1111-111111111111"
$producer = "smartbuket-sdk"
$actor = "anonymous"

if ($FreshIds) {
  $traceId = [guid]::NewGuid().ToString()
  $id1 = [guid]::NewGuid().ToString()
  $id2 = [guid]::NewGuid().ToString()
  $id3 = [guid]::NewGuid().ToString()
} else {
  $id1 = "00000000-0000-0000-0000-000000000001"
  $id2 = "00000000-0000-0000-0000-000000000002"
  $id3 = "00000000-0000-0000-0000-000000000003"
}

# Use UTC hours so it matches processor bucketing
$now = [datetime]::UtcNow
$hour0 = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, 0, 0, [DateTimeKind]::Utc)
$hour1 = $hour0.AddHours(-1)

# Demo coordinates (Santo Domingo as example)
$lat = 18.4861
$lon = -69.9312

$events = @(
  # License event (goes to sb.events.license + upserts license_state)
  @{
    event_id = $id1
    trace_id = $traceId
    producer = $producer
    actor = $actor

    app_uuid = $appUuid
    event_type = "license.update"
    timestamp = (To-IsoUtc $hour0.AddMinutes(2))
    event_name = "license.update"
    occurred_at = (To-IsoUtc $hour0.AddMinutes(2))
    anon_user_id = $anonUserId
    device_id_hash = $deviceHash
    session_id = $sessionHash
    sdk_version = $sdkVersion
    event_version = $eventVersion
    payload = @{
      plan_type = "subscription"
      license_status = "expired"
      started_at = (To-IsoUtc $hour1.AddDays(-40))
      renewed_at = (To-IsoUtc $hour1.AddDays(-10))
      expires_at = (To-IsoUtc $hour1.AddDays(-1))
    }
    context = @{
      device = @{ model = "demo" }
      os = @{ name = "windows"; version = "11" }
      geo = @{ lat = $lat; lon = $lon; accuracy_m = 120; source = "network" }
    }
  }

  # geo.ping in previous hour
  ,@{
    event_id = $id2
    trace_id = $traceId
    producer = $producer
    actor = $actor

    app_uuid = $appUuid
    event_type = "geo.ping"
    timestamp = (To-IsoUtc $hour1.AddMinutes(10))
    event_name = "geo.ping"
    occurred_at = (To-IsoUtc $hour1.AddMinutes(10))
    anon_user_id = $anonUserId
    device_id_hash = $deviceHash
    session_id = $sessionHash
    sdk_version = $sdkVersion
    event_version = $eventVersion
    payload = @{ reason = "timer_10m" }
    context = @{
      device = @{ model = "demo" }
      os = @{ name = "windows"; version = "11" }
      geo = @{ lat = $lat; lon = $lon; accuracy_m = 25; source = "gps" }
    }
  }

  # geo.ping in current hour
  ,@{
    event_id = $id3
    trace_id = $traceId
    producer = $producer
    actor = $actor

    app_uuid = $appUuid
    event_type = "geo.ping"
    timestamp = (To-IsoUtc $hour0.AddMinutes(5))
    event_name = "geo.ping"
    occurred_at = (To-IsoUtc $hour0.AddMinutes(5))
    anon_user_id = $anonUserId
    device_id_hash = $deviceHash
    session_id = $sessionHash
    sdk_version = $sdkVersion
    event_version = $eventVersion
    payload = @{ reason = "app_open" }
    context = @{
      device = @{ model = "demo" }
      os = @{ name = "windows"; version = "11" }
      geo = @{ lat = $lat; lon = $lon; accuracy_m = 20; source = "gps" }
    }
  }
)

Write-Host "Posting batch to ingest: $($events.Count) events" -ForegroundColor Cyan
$ingestUrl = "$IngestBase/v1/events"
$ingestResp = Invoke-RestMethod -Method Post -Uri $ingestUrl -ContentType "application/json" -Body ($events | ConvertTo-Json -Depth 12)
$ingestResp | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Waiting $WaitSeconds seconds for outbox+processor to consume broker messages..." -ForegroundColor Cyan
Start-Sleep -Seconds $WaitSeconds

# Query window: last 2 hours
$start = (To-IsoUtc $hour1.AddMinutes(-1))
$end = (To-IsoUtc $hour0.AddHours(1))

Write-Host "Query DAH (devices/hour)" -ForegroundColor Cyan
$q1 = "$QueryBase/v1/metrics/active-devices-hourly?start=$start&end=$end&app_uuid=$appUuid"
Invoke-RestMethod -Uri $q1 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Query UAH (users/hour)" -ForegroundColor Cyan
$q2 = "$QueryBase/v1/metrics/active-users-hourly?start=$start&end=$end&app_uuid=$appUuid"
Invoke-RestMethod -Uri $q2 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Query Peak Hour (devices)" -ForegroundColor Cyan
$q3 = "$QueryBase/v1/metrics/peak-hour?start=$start&end=$end&app_uuid=$appUuid&dimension=devices"
Invoke-RestMethod -Uri $q3 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Query Heatmap H3 (res=9, devices)" -ForegroundColor Cyan
$q4 = "$QueryBase/v1/metrics/heatmap/h3?start=$start&end=$end&resolution=9&metric=devices&app_uuid=$appUuid"
Invoke-RestMethod -Uri $q4 | Select-Object -First 5 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Checking Query API OpenAPI for /v1/aggregates/* ..." -ForegroundColor Cyan
$hasAggregates = $false
try {
  $openApi = Invoke-RestMethod -Uri "$QueryBase/openapi.json"
  $paths = @($openApi.paths.PSObject.Properties.Name)
  $hasAggregates = ($paths | Where-Object { $_ -like '/v1/aggregates/*' }).Count -gt 0
} catch {
  $hasAggregates = $false
}

if (-not $hasAggregates) {
  Write-Host "Skipping aggregates: Query API does not expose /v1/aggregates/* in OpenAPI (you are running an older query-api)." -ForegroundColor Yellow
  Write-Host "Fix: restart ONLY query-api from CMD: scripts\\restart-query.cmd" -ForegroundColor Yellow
} else {
  Write-Host "Query Aggregates: H3 r9 hourly (devices/users)" -ForegroundColor Cyan
  $a1 = "$QueryBase/v1/aggregates/h3-r9-hourly?start=$start&end=$end&app_uuid=$appUuid"
  Invoke-RestMethod -Uri $a1 | Select-Object -First 10 | ConvertTo-Json -Depth 20 | Write-Host

  Write-Host "Query Aggregates: Place hourly (devices/users)" -ForegroundColor Cyan
  $a2 = "$QueryBase/v1/aggregates/place-hourly?start=$start&end=$end&app_uuid=$appUuid"
  Invoke-RestMethod -Uri $a2 | Select-Object -First 10 | ConvertTo-Json -Depth 20 | Write-Host

  Write-Host "Query Aggregates: Admin hourly (country)" -ForegroundColor Cyan
  $a3 = "$QueryBase/v1/aggregates/admin-hourly?start=$start&end=$end&app_uuid=$appUuid&level=country"
  Invoke-RestMethod -Uri $a3 | Select-Object -First 10 | ConvertTo-Json -Depth 20 | Write-Host
}

Write-Host "Query App Share (devices)" -ForegroundColor Cyan
$q5 = "$QueryBase/v1/metrics/app-share?start=$start&end=$end&metric=devices"
Invoke-RestMethod -Uri $q5 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Get Offers (should include renewal/plan offer due to expired license)" -ForegroundColor Cyan
$o1 = "$RecoBase/v1/offers?anon_user_id=$anonUserId"
Invoke-RestMethod -Uri $o1 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Get Offers (scoped by app_uuid)" -ForegroundColor Cyan
$o2 = "$RecoBase/v1/offers?anon_user_id=$anonUserId&app_uuid=$appUuid"
Invoke-RestMethod -Uri $o2 | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Done." -ForegroundColor Green

<###
Optional: same batch via curl (PowerShell will call curl.exe if present)

$eventsJson = ($events | ConvertTo-Json -Depth 12)
$eventsJson | Set-Content -Encoding utf8 .\events.json
curl -X POST "$IngestBase/v1/events" -H "Content-Type: application/json" --data-binary "@events.json"
###>
