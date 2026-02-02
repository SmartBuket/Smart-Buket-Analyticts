param(
  [switch]$StartStack,
  [switch]$Hardening,
  [switch]$StrictEnvelope,
  [switch]$Diagnostics,
  [switch]$ForceFailWait,
  [string]$CorsOrigin = "http://localhost:3000",
  [string]$IngestBase = "http://localhost:8001",
  [string]$QueryBase  = "http://localhost:8002",
  [string]$RecoBase   = "http://localhost:8003",
  [int]$WaitSeconds   = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True($cond, [string]$msg) {
  if (-not $cond) { throw "ASSERT FAILED: $msg" }
}

function To-IsoUtc([datetime]$dt) {
  return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-Headers([string]$url) {
  $r = Invoke-WebRequest -UseBasicParsing -Uri $url
  return $r.Headers
}

function Wait-For([scriptblock]$fn, [int]$timeoutSeconds = 20, [int]$intervalMs = 500) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $res = & $fn
      if ($res) { return $true }
    } catch {
      $script:LastWaitError = $_
      # ignore transient errors while services warm up
    }
    Start-Sleep -Milliseconds $intervalMs
  }
  return $false
}

function Normalize-ApiList($resp) {
  if ($null -eq $resp) { return @() }
  if ($resp -is [System.Array]) { return @($resp) }
  try {
    if ($resp.PSObject -and ($resp.PSObject.Properties.Name -contains 'value')) {
      return @($resp.value)
    }
  } catch {}
  return @($resp)
}

function Write-Diag([string]$msg) {
  if ($Diagnostics) {
    Write-Host ("[diag] " + $msg) -ForegroundColor DarkGray
  }
}

function Format-ErrorRecord([object]$err) {
  if ($null -eq $err) { return '' }
  try {
    return ($err | Format-List * -Force | Out-String -Width 200)
  } catch {
    try { return [string]$err } catch { return '' }
  }
}

function Format-Exception([System.Exception]$ex) {
  if ($null -eq $ex) { return '' }
  $lines = @()
  $lines += ("{0}: {1}" -f $ex.GetType().FullName, $ex.Message)
  if ($ex.StackTrace) { $lines += "StackTrace:`n$($ex.StackTrace)" }
  if ($ex.InnerException) {
    $lines += "InnerException:" 
    $lines += ("{0}: {1}" -f $ex.InnerException.GetType().FullName, $ex.InnerException.Message)
    if ($ex.InnerException.StackTrace) { $lines += "Inner StackTrace:`n$($ex.InnerException.StackTrace)" }
  }
  return ($lines -join "`n")
}

if ($Hardening) {
  $env:SB_HARDENING_ENABLED = '1'
  $env:SB_HSTS_SECONDS = '60'
  $env:SB_HSTS_PRELOAD = '0'
  $env:SB_CORS_ALLOW_ORIGINS = $CorsOrigin
} else {
  $env:SB_HARDENING_ENABLED = '0'
}

if ($StrictEnvelope) {
  $env:SB_STRICT_ENVELOPE = '1'
} else {
  $env:SB_STRICT_ENVELOPE = '0'
}

if ($StartStack) {
  Write-Host 'Starting stack (run-all.ps1)...' -ForegroundColor Cyan
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-all.ps1
}

Write-Host '1) Checking /health endpoints...' -ForegroundColor Cyan
$h1 = Get-Headers "$IngestBase/health"
$h2 = Get-Headers "$QueryBase/health"
$h3 = Get-Headers "$RecoBase/health"

Write-Host '2) Checking hardening headers (if enabled)...' -ForegroundColor Cyan
if ($Hardening) {
  foreach ($h in @($h1,$h2,$h3)) {
    Assert-True ($h['x-content-type-options'] -eq 'nosniff') 'missing x-content-type-options'
    Assert-True ($h['referrer-policy'] -eq 'no-referrer') 'missing referrer-policy'
    Assert-True ($h['x-frame-options'] -eq 'DENY') 'missing x-frame-options'
    Assert-True ($h['permissions-policy']) 'missing permissions-policy'
    Assert-True ($h['strict-transport-security']) 'missing strict-transport-security'
  }

  $preflightHeaders = @{
    Origin=$CorsOrigin
    'Access-Control-Request-Method'='POST'
    'Access-Control-Request-Headers'='Content-Type,X-Trace-Id,X-App-Uuid,Authorization'
  }
  $pre = Invoke-WebRequest -UseBasicParsing -Method Options -Uri "$IngestBase/v1/events" -Headers $preflightHeaders
  Assert-True ($pre.StatusCode -ge 200 -and $pre.StatusCode -lt 300) 'CORS preflight failed'
  Assert-True ($pre.Headers['access-control-allow-origin'] -eq $CorsOrigin) 'CORS allow-origin mismatch'
}

Write-Host '3) Checking strict envelope rejection (if enabled)...' -ForegroundColor Cyan
if ($StrictEnvelope) {
  $legacy = @(@{ app_uuid='b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7'; event_type='geo.ping'; timestamp='2020-01-01T00:00:00Z'; payload=@{} })
  try {
    Invoke-RestMethod -Method Post -Uri "$IngestBase/v1/events" -ContentType 'application/json' -Body ($legacy | ConvertTo-Json -Depth 6) | Out-Null
    throw 'Legacy payload unexpectedly accepted in strict mode'
  } catch {
    # expecting 422
    $code = $_.Exception.Response.StatusCode.value__
    Assert-True ($code -eq 422) "Expected 422 for legacy payload, got $code"
  }
}

Write-Host '4) Posting events and verifying outputs...' -ForegroundColor Cyan
$appUuid      = 'b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7'
$anonUserId   = 'u_demo_4f1c9b2d9a9c1f0d0a0b3c_demo'
$deviceHash   = 'd_demo_aa93c0f1b1d6c2_demo'
$sessionHash  = 's_demo_2c9aa1c0d3_demo'

$traceId = [guid]::NewGuid().ToString()
$now = [datetime]::UtcNow
$hour0 = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, 0, 0, [DateTimeKind]::Utc)
$hour1 = $hour0.AddHours(-1)

$lat = 18.4861
$lon = -69.9312

$e1 = @{
  event_id = [guid]::NewGuid().ToString()
  trace_id = $traceId
  producer = 'smoke-test'
  actor = 'anonymous'
  app_uuid = $appUuid
  event_name = 'license.update'
  occurred_at = (To-IsoUtc $hour0.AddMinutes(2))
  anon_user_id = $anonUserId
  device_id_hash = $deviceHash
  session_id = $sessionHash
  sdk_version = '1.0.0'
  event_version = '1'
  payload = @{ plan_type='subscription'; license_status='expired'; expires_at=(To-IsoUtc $hour1.AddDays(-1)) }
  context = @{ geo=@{ lat=$lat; lon=$lon; accuracy_m=120; source='network' } }
}

$e2 = @{
  event_id = [guid]::NewGuid().ToString()
  trace_id = $traceId
  producer = 'smoke-test'
  actor = 'anonymous'
  app_uuid = $appUuid
  event_name = 'geo.ping'
  occurred_at = (To-IsoUtc $hour1.AddMinutes(10))
  anon_user_id = $anonUserId
  device_id_hash = $deviceHash
  session_id = $sessionHash
  sdk_version = '1.0.0'
  event_version = '1'
  payload = @{ reason='timer_10m' }
  context = @{ geo=@{ lat=$lat; lon=$lon; accuracy_m=25; source='gps' } }
}

$e3 = @{
  event_id = [guid]::NewGuid().ToString()
  trace_id = $traceId
  producer = 'smoke-test'
  actor = 'anonymous'
  app_uuid = $appUuid
  event_name = 'geo.ping'
  occurred_at = (To-IsoUtc $hour0.AddMinutes(5))
  anon_user_id = $anonUserId
  device_id_hash = $deviceHash
  session_id = $sessionHash
  sdk_version = '1.0.0'
  event_version = '1'
  payload = @{ reason='app_open' }
  context = @{ geo=@{ lat=$lat; lon=$lon; accuracy_m=20; source='gps' } }
}

$batch = @($e1,$e2,$e3)
$script:LastIngestResponse = $null
$script:LastDahResponse = $null
$script:LastDahRows = @()
$script:LastWaitError = $null

$ingest = Invoke-RestMethod -Method Post -Uri "$IngestBase/v1/events" -ContentType 'application/json' -Body ($batch | ConvertTo-Json -Depth 12)
$script:LastIngestResponse = $ingest
if ($Diagnostics) {
  try {
    Write-Diag ("ingest response: " + ($ingest | ConvertTo-Json -Depth 8 -Compress))
  } catch {}
}
Assert-True ($ingest.accepted -eq 3) "Expected accepted=3, got $($ingest.accepted)"
Assert-True ($ingest.rejected.Count -eq 0) 'Expected rejected=[]'

$start = (To-IsoUtc $hour1.AddMinutes(-1))
$end = (To-IsoUtc $hour0.AddHours(1))
Write-Diag ("trace_id=$traceId app_uuid=$appUuid start=$start end=$end")

Write-Host 'Waiting for processor results to show up in query-api...' -ForegroundColor Cyan
$dahUrl = "$QueryBase/v1/metrics/active-devices-hourly?start=$start&end=$end&app_uuid=$appUuid"
Write-Diag ("DAH url: $dahUrl")
if ($ForceFailWait) {
  Write-Diag 'ForceFailWait=1 (forcing DAH wait to time out for diagnostics test)'
}
$ok = Wait-For -timeoutSeconds ([Math]::Max(10, $WaitSeconds)) -fn {
  $dah = Invoke-RestMethod -Uri $dahUrl
  $script:LastDahResponse = $dah
  $rows = Normalize-ApiList $dah
  $script:LastDahRows = $rows
  return (-not $ForceFailWait) -and ($rows.Count -ge 1)
}
if (-not $ok -and $Diagnostics) {
  try {
    Write-Diag ("last DAH response: " + ($script:LastDahResponse | ConvertTo-Json -Depth 8 -Compress))
  } catch {}
  try {
    Write-Diag ("last DAH rows count: {0}" -f @($script:LastDahRows).Count)
  } catch {}
  try {
    if (@($script:LastDahRows).Count -gt 0) {
      $preview = @($script:LastDahRows | Select-Object -First 5)
      Write-Diag ("last DAH rows (first 5): " + ($preview | ConvertTo-Json -Depth 6 -Compress))
    }
  } catch {}
  if ($script:LastWaitError) {
    try {
      Write-Diag ("last wait error record:`n" + (Format-ErrorRecord $script:LastWaitError))
    } catch {}
    try {
      $ex = $script:LastWaitError.Exception
      Write-Diag ("last wait exception:`n" + (Format-Exception $ex))
    } catch {}
  }
}
Assert-True $ok 'Timed out waiting for DAH rows >= 1'

$dah = Invoke-RestMethod -Uri $dahUrl
$dahRows = Normalize-ApiList $dah
if ($Diagnostics) {
  try {
    $preview = @($dahRows | Select-Object -First 3)
    Write-Diag ("DAH rows (first 3): " + ($preview | ConvertTo-Json -Depth 6 -Compress))
  } catch {}
}
Assert-True ($dahRows.Count -ge 1) 'Expected DAH rows >= 1'

$offers = Invoke-RestMethod -Uri "$RecoBase/v1/offers?anon_user_id=$anonUserId&app_uuid=$appUuid"
Assert-True ($offers.offers.Count -ge 1) 'Expected at least one offer'
$planOffers = @($offers.offers | Where-Object { $_.type -eq 'plan' })
Assert-True ($planOffers.Count -ge 1) 'Expected a plan offer'

Write-Host 'E2E SMOKE PASS' -ForegroundColor Green
