param(
  [string]$MetabaseUrl = 'http://localhost:3001',
  [string]$SiteName = 'SmartBuket Analytics',
  [string]$SiteLocale = 'es',
  [string]$AdminEmail = 'admin@smartbuket.com',
  [string]$AdminFirstName = 'Admin',
  [string]$AdminLastName = 'SmartBuket',
  [string]$AdminPassword = '',
  [string]$DbHost = 'sb-postgres',
  [int]$DbPort = 5432,
  [string]$DbName = 'sb_analytics',
  [string]$DbUser = 'sb',
  [string]$DbPassword = 'sb',
  [bool]$CleanupSample = $true,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-Url([string]$base, [string]$path) {
  if ($base.EndsWith('/')) { $base = $base.TrimEnd('/') }
  if (-not $path.StartsWith('/')) { $path = '/' + $path }
  return $base + $path
}

function Wait-ForMetabase([int]$timeoutSeconds = 120) {
  $healthUrl = Join-Url $MetabaseUrl '/api/health'
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-RestMethod -Method Get -Uri $healthUrl -TimeoutSec 3
      if ($h.status -eq 'ok') { return }
    } catch {
      Start-Sleep -Milliseconds 750
    }
  }
  throw "Metabase did not become healthy within ${timeoutSeconds}s: $healthUrl"
}

function Get-SessionProperties {
  $propsUrl = Join-Url $MetabaseUrl '/api/session/properties'
  return (Invoke-RestMethod -Method Get -Uri $propsUrl -TimeoutSec 10)
}

function New-MetabaseSessionToken {
  $url = Join-Url $MetabaseUrl '/api/session'
  $body = (@{ username = $AdminEmail; password = $AdminPassword } | ConvertTo-Json)
  $resp = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body $body -TimeoutSec 20
  return $resp.id
}

function Invoke-MetabaseApi {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Get','Post','Put','Delete','Patch')]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [object]$BodyObject = $null,
    [int]$TimeoutSec = 30
  )

  $url = Join-Url $MetabaseUrl $Path
  $headers = @{ 'X-Metabase-Session' = $SessionToken }
  if ($null -eq $BodyObject) {
    return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -TimeoutSec $TimeoutSec)
  }
  $json = $BodyObject | ConvertTo-Json -Depth 10
  return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec $TimeoutSec)
}

function Set-MetabaseSetting {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [string]$Key,

    [Parameter(Mandatory = $true)]
    [object]$Value
  )

  # Metabase setting endpoints are a bit inconsistent across versions.
  # Try a couple shapes to keep this script resilient.
  try {
    Invoke-MetabaseApi -Method Put -Path ("/api/setting/{0}" -f $Key) -SessionToken $SessionToken -BodyObject @{ value = $Value } -TimeoutSec 30 | Out-Null
    return
  } catch {
    # Fall through
  }

  try {
    Invoke-MetabaseApi -Method Put -Path ("/api/setting/{0}" -f $Key) -SessionToken $SessionToken -BodyObject $Value -TimeoutSec 30 | Out-Null
    return
  } catch {
    $msg = $_.Exception.Message
    try {
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + "`n" + $_.ErrorDetails.Message }
    } catch {}
    throw "Failed to set Metabase setting '$Key': $msg"
  }
}

function Ensure-SiteBranding([string]$SessionToken) {
  Write-Host ("Ensuring Metabase site branding: '{0}' ({1})" -f $SiteName, $SiteLocale) -ForegroundColor Cyan

  # Keys follow Metabase's API naming. These work on v0.58.x.
  Set-MetabaseSetting -SessionToken $SessionToken -Key 'site-name' -Value $SiteName
  Set-MetabaseSetting -SessionToken $SessionToken -Key 'site-locale' -Value $SiteLocale

  # Best-effort: disable anonymous tracking.
  try {
    Set-MetabaseSetting -SessionToken $SessionToken -Key 'anon-tracking-enabled' -Value $false
  } catch {
    Write-Warning ("Could not disable tracking (non-fatal): {0}" -f $_.Exception.Message)
  }
}

function Remove-SampleDatabaseIfPresent([string]$SessionToken) {
  try {
    $dbs = Invoke-MetabaseApi -Method Get -Path '/api/database' -SessionToken $SessionToken -TimeoutSec 30
    $items = @($dbs.data)
    $sample = $items | Where-Object { $_.name -eq 'Sample Database' -or $_.engine -eq 'h2' }
    foreach ($db in $sample) {
      Write-Host ("Removing Metabase sample DB: {0} (id={1})" -f $db.name, $db.id) -ForegroundColor Yellow
      Invoke-MetabaseApi -Method Delete -Path ("/api/database/{0}" -f $db.id) -SessionToken $SessionToken -TimeoutSec 30 | Out-Null
    }
  } catch {
    Write-Warning ("Could not remove sample database (non-fatal): {0}" -f $_.Exception.Message)
  }
}

function Ensure-SmartBuketDatabase([string]$SessionToken) {
  $desiredName = 'SmartBuket Analytics (sb_analytics)'
  try {
    $dbs = Invoke-MetabaseApi -Method Get -Path '/api/database' -SessionToken $SessionToken -TimeoutSec 30
    $items = @($dbs.data)
    $existing = $items | Where-Object { $_.name -eq $desiredName } | Select-Object -First 1
    if ($existing) {
      Write-Host ("Metabase DB already present: {0} (id={1})" -f $existing.name, $existing.id) -ForegroundColor Green
      return
    }

    Write-Host ("Creating Metabase DB: {0}" -f $desiredName) -ForegroundColor Cyan
    $body = @{
      name = $desiredName
      engine = 'postgres'
      details = @{
        host = $DbHost
        port = $DbPort
        dbname = $DbName
        user = $DbUser
        password = $DbPassword
        ssl = $false
      }
      is_full_sync = $true
      is_on_demand = $false
    }

    $created = Invoke-MetabaseApi -Method Post -Path '/api/database' -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60
    if ($created -and $created.id) {
      Write-Host ("Metabase DB created (id={0})." -f $created.id) -ForegroundColor Green
    }
  } catch {
    Write-Warning ("Could not ensure SmartBuket DB in Metabase (non-fatal): {0}" -f $_.Exception.Message)
  }
}

function Ensure-AdminPassword {
  if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    if (-not [string]::IsNullOrWhiteSpace($env:MB_ADMIN_PASSWORD)) {
      $script:AdminPassword = [string]$env:MB_ADMIN_PASSWORD
      return
    }
    $sec = Read-Host -Prompt 'Metabase admin password (dev)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $script:AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    throw 'AdminPassword is required (empty after prompt).'
  }
}

Write-Host "Metabase bootstrap -> $MetabaseUrl" -ForegroundColor Cyan
Wait-ForMetabase

$props = Get-SessionProperties
if ($props.'has-user-setup' -eq $true -and -not $Force) {
  Write-Host 'Metabase is already set up.' -ForegroundColor Green

  # Even if Metabase is already initialized, we still want idempotent branding.
  Ensure-AdminPassword
  try {
    $token = New-MetabaseSessionToken
    Ensure-SiteBranding -SessionToken $token

    Write-Host 'Ensuring SmartBuket DB exists...' -ForegroundColor Cyan
    Ensure-SmartBuketDatabase -SessionToken $token

    if ($CleanupSample) {
      Write-Host 'Cleaning up Metabase sample content (optional)...' -ForegroundColor Cyan
      Remove-SampleDatabaseIfPresent -SessionToken $token
      Write-Host 'Sample content cleanup done.' -ForegroundColor Green
    }
  } catch {
    Write-Warning ("Post-setup configuration failed (non-fatal): {0}" -f $_.Exception.Message)
  }

  Write-Host 'Nothing else to do.' -ForegroundColor DarkGray
  Write-Host 'Tip: run with -Force to re-run setup (may fail if already initialized).' -ForegroundColor DarkGray
  return
}

$setupToken = $props.'setup-token'
if ([string]::IsNullOrWhiteSpace($setupToken)) {
  if ($props.'has-user-setup' -eq $true) {
    Write-Host 'Metabase is already set up (no setup-token). Nothing to do.' -ForegroundColor Green
    return
  }
  throw 'Metabase did not provide a setup-token; cannot bootstrap.'
}

Ensure-AdminPassword

$payload = @{
  token = $setupToken
  prefs = @{
    site_name = $SiteName
    site_locale = $SiteLocale
    allow_tracking = $false
  }
  user = @{
    first_name = $AdminFirstName
    last_name = $AdminLastName
    email = $AdminEmail
    password = $AdminPassword
  }
  database = @{
    engine = 'postgres'
    name = 'SmartBuket Analytics (sb_analytics)'
    details = @{
      host = $DbHost
      port = $DbPort
      dbname = $DbName
      user = $DbUser
      password = $DbPassword
      ssl = $false
    }
    is_full_sync = $true
    is_on_demand = $false
  }
}

$setupUrl = Join-Url $MetabaseUrl '/api/setup'
$body = $payload | ConvertTo-Json -Depth 10

Write-Host 'Running Metabase initial setup (this is one-time)...' -ForegroundColor Cyan
try {
  $resp = Invoke-RestMethod -Method Post -Uri $setupUrl -ContentType 'application/json' -Body $body -TimeoutSec 60
} catch {
  $msg = $_.Exception.Message
  try {
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + "`n" + $_.ErrorDetails.Message }
  } catch {}
  throw "Metabase setup failed: $msg"
}

Write-Host 'Metabase setup completed.' -ForegroundColor Green
Write-Host ("UI: {0}" -f $MetabaseUrl) -ForegroundColor Green
Write-Host ("Login: {0}" -f $AdminEmail) -ForegroundColor Green
Write-Host 'Note: Password is what you entered in the prompt / -AdminPassword.' -ForegroundColor DarkGray

if (-not $CleanupSample) {
  Write-Host 'Skipping sample DB cleanup.' -ForegroundColor DarkGray
  return
}

Write-Host 'Cleaning up Metabase sample content (optional)...' -ForegroundColor Cyan
try {
  $token = New-MetabaseSessionToken
  Ensure-SmartBuketDatabase -SessionToken $token
  Remove-SampleDatabaseIfPresent -SessionToken $token
  Write-Host 'Sample content cleanup done.' -ForegroundColor Green
} catch {
  Write-Warning ("Cleanup failed (non-fatal): {0}" -f $_.Exception.Message)
}
