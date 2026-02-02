param(
  [string]$MetabaseUrl = 'http://localhost:3001',
  [string]$Email = 'admin@smartbuket.com',
  [string]$Password = '',
  [string]$DbDisplayName = 'SmartBuket Analytics (sb_analytics)',
  [string]$AppUuid = '',
  [switch]$UseDockerAutodetect,
  [string]$DateRangeDefault = 'past7days',
  [bool]$ArchiveDuplicateDashboards = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-Url([string]$base, [string]$path) {
  if ($base.EndsWith('/')) { $base = $base.TrimEnd('/') }
  if (-not $path.StartsWith('/')) { $path = '/' + $path }
  return $base + $path
}

function Ensure-Password {
  if (-not [string]::IsNullOrWhiteSpace($Password)) { return }
  $sec = Read-Host -Prompt "Metabase password for $Email" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $script:Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if ([string]::IsNullOrWhiteSpace($Password)) { throw 'Password is required.' }
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

function New-MetabaseSessionToken {
  Ensure-Password
  $url = Join-Url $MetabaseUrl '/api/session'
  $body = (@{ username = $Email; password = $Password } | ConvertTo-Json)
  $resp = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body $body -TimeoutSec 20
  if (-not $resp.id) { throw 'Could not obtain Metabase session token.' }
  return $resp.id
}

function Invoke-Mb {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Get','Post','Put','Delete')]
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

  $script:LastMbRequest = @{ Method = $Method; Path = $Path; Url = $url }
  $script:LastMbBodyJson = $null

  if ($null -eq $BodyObject) {
    try {
      return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -TimeoutSec $TimeoutSec)
    } catch {
      $details = ''
      try {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $details = $_.ErrorDetails.Message }
      } catch {}
      $msg = $_.Exception.Message
      if (-not [string]::IsNullOrWhiteSpace($details)) { $msg = $msg + "\n" + $details }
      throw "Metabase API call failed: $Method $Path ($url)\n$msg"
    }
  }

  $json = $BodyObject | ConvertTo-Json -Depth 20 -Compress
  $script:LastMbBodyJson = $json
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec)
  } catch {
    $details = ''
    try {
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $details = $_.ErrorDetails.Message }
    } catch {}
    $msg = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($details)) { $msg = $msg + "\n" + $details }
    throw "Metabase API call failed: $Method $Path ($url)\n$msg"
  }
}

function Get-DatabaseId([string]$SessionToken) {
  $dbs = Invoke-Mb -Method Get -Path '/api/database' -SessionToken $SessionToken
  $items = @($dbs.data)
  $db = $items | Where-Object { $_.name -eq $DbDisplayName } | Select-Object -First 1
  if ($db) { return [int]$db.id }

  Write-Host "Metabase DB '$DbDisplayName' not found; creating it..." -ForegroundColor Yellow
  $createBody = @{
    name = $DbDisplayName
    engine = 'postgres'
    details = @{
      host = 'sb-postgres'
      port = 5432
      dbname = 'sb_analytics'
      user = 'sb'
      password = 'sb'
      ssl = $false
    }
    is_full_sync = $true
    is_on_demand = $false
  }

  $created = Invoke-Mb -Method Post -Path '/api/database' -SessionToken $SessionToken -BodyObject $createBody -TimeoutSec 60
  if (-not $created.id) {
    throw 'Failed to create Metabase database connection.'
  }
  return [int]$created.id
}

function Ensure-Collection([string]$SessionToken, [string]$Name) {
  $cols = Invoke-Mb -Method Get -Path '/api/collection' -SessionToken $SessionToken
  $existing = @($cols) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if ($existing) { return [int]$existing.id }

  $created = Invoke-Mb -Method Post -Path '/api/collection' -SessionToken $SessionToken -BodyObject @{ name = $Name; color = '#2D9CDB' }
  return [int]$created.id
}

function Create-Card {
  param(
    [string]$SessionToken,
    [int]$CollectionId,
    [int]$DatabaseId,
    [string]$Name,
    [string]$Display,
    [string]$Sql,
    [hashtable]$TemplateTags = $null,
    [hashtable]$VisualizationSettings = $null,
    [string]$Description = ''
  )

  $cardBody = @{
    name = $Name
    collection_id = $CollectionId
    display = $Display
    dataset_query = @{
      database = $DatabaseId
      type = 'native'
      native = @{
        query = $Sql
      }
    }
    visualization_settings = @{}
  }

  if ($null -ne $VisualizationSettings) {
    $cardBody.visualization_settings = $VisualizationSettings
  }

  if ($null -ne $TemplateTags -and $TemplateTags.Keys.Count -gt 0) {
    $cardBody.dataset_query.native.'template-tags' = $TemplateTags
  }

  if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $cardBody.description = $Description
  }

  $card = Invoke-Mb -Method Post -Path '/api/card' -SessionToken $SessionToken -BodyObject $cardBody
  return [int]$card.id
}

function Search-Mb {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [string]$Query,

    [string[]]$Models = @()
  )

  $q = [Uri]::EscapeDataString($Query)
  $path = "/api/search?q=$q"
  if ($Models -and $Models.Count -gt 0) {
    $m = [Uri]::EscapeDataString(($Models -join ','))
    $path = $path + "&models=$m"
  }

  try {
    $resp = Invoke-Mb -Method Get -Path $path -SessionToken $SessionToken -TimeoutSec 60
    if ($null -ne $resp -and $null -ne $resp.data) {
      return @($resp.data)
    }
    return @($resp)
  } catch {
    # Some Metabase builds may not expose /api/search. Fall back to empty.
    return @()
  }
}

function Get-Dashboard {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [int]$DashboardId
  )

  return (Invoke-Mb -Method Get -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -TimeoutSec 60)
}

function Find-DashboardByName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$CollectionId
  )

  $results = Search-Mb -SessionToken $SessionToken -Query $Name -Models @('dashboard')
  foreach ($r in $results) {
    if ($r.model -ne 'dashboard') { continue }
    if ($r.name -ne $Name) { continue }
    if ($null -ne $r.collection -and [int]$r.collection.id -ne $CollectionId) { continue }
    return [int]$r.id
  }
  return $null
}

function Set-DashboardArchived {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [int]$DashboardId
  )

  $d = Invoke-Mb -Method Get -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -TimeoutSec 60
  $body = @{
    name = $d.name
    description = $d.description
    collection_id = $d.collection_id
    parameters = @($d.parameters)
    archived = $true
  }

  Invoke-Mb -Method Put -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60 | Out-Null
}

function ConvertTo-DateTime([object]$v) {
  if ($null -eq $v) { return [datetime]::MinValue }
  try { return [datetime]::Parse([string]$v) } catch { return [datetime]::MinValue }
}

function Archive-DuplicateDashboardsByName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$CollectionId
  )

  $matches = Search-Mb -SessionToken $SessionToken -Query $Name -Models @('dashboard') | Where-Object {
    $_.model -eq 'dashboard' -and $_.name -eq $Name -and $_.archived -ne $true -and $_.collection -and ([int]$_.collection.id -eq $CollectionId)
  }

  if (-not $matches -or @($matches).Count -le 1) {
    return $null
  }

  $keep = @($matches) | Sort-Object @{ Expression = { ConvertTo-DateTime $_.updated_at }; Descending = $true }, @{ Expression = { ConvertTo-DateTime $_.created_at }; Descending = $true } | Select-Object -First 1
  $keepId = [int]$keep.id

  $toArchive = @($matches | Where-Object { [int]$_.id -ne $keepId })
  foreach ($d in $toArchive) {
    Write-Host ("Archiving duplicate dashboard id={0} (keeping id={1})" -f $d.id, $keepId) -ForegroundColor Yellow
    Set-DashboardArchived -SessionToken $SessionToken -DashboardId ([int]$d.id)
  }

  return $keepId
}

function Ensure-Dashboard {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [int]$CollectionId,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $existingId = Find-DashboardByName -SessionToken $SessionToken -Name $Name -CollectionId $CollectionId
  if ($existingId) {
    Write-Host ("Reusing existing dashboard: {0} (id={1})" -f $Name, $existingId) -ForegroundColor Green
    return [int]$existingId
  }

  $body = @{
    name = $Name
    description = $Description
    collection_id = $CollectionId
  }

  $dash = Invoke-Mb -Method Post -Path '/api/dashboard' -SessionToken $SessionToken -BodyObject $body
  return [int]$dash.id
}

function Find-CardByName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SessionToken,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [int]$CollectionId
  )

  $results = Search-Mb -SessionToken $SessionToken -Query $Name -Models @('card')
  foreach ($r in $results) {
    if ($r.model -ne 'card') { continue }
    if ($r.name -ne $Name) { continue }
    if ($null -ne $r.collection -and [int]$r.collection.id -ne $CollectionId) { continue }
    return [int]$r.id
  }
  return $null
}

function Ensure-Card {
  param(
    [string]$SessionToken,
    [int]$CollectionId,
    [int]$DatabaseId,
    [string]$Name,
    [string]$Display,
    [string]$Sql,
    [hashtable]$TemplateTags = $null,
    [hashtable]$VisualizationSettings = $null,
    [string]$Description = ''
  )

  $existingId = Find-CardByName -SessionToken $SessionToken -Name $Name -CollectionId $CollectionId
  if (-not $existingId) {
    return (Create-Card -SessionToken $SessionToken -CollectionId $CollectionId -DatabaseId $DatabaseId -Name $Name -Display $Display -Sql $Sql -TemplateTags $TemplateTags -VisualizationSettings $VisualizationSettings -Description $Description)
  }

  $body = @{
    name = $Name
    collection_id = $CollectionId
    display = $Display
    dataset_query = @{
      database = $DatabaseId
      type = 'native'
      native = @{
        query = $Sql
      }
    }
    visualization_settings = @{}
  }

  if ($null -ne $VisualizationSettings) {
    $body.visualization_settings = $VisualizationSettings
  }
  if ($null -ne $TemplateTags -and $TemplateTags.Keys.Count -gt 0) {
    $body.dataset_query.native.'template-tags' = $TemplateTags
  }
  if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $body.description = $Description
  }

  Invoke-Mb -Method Put -Path ("/api/card/{0}" -f $existingId) -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60 | Out-Null
  return [int]$existingId
}



function Update-DashboardParameters {
  param(
    [string]$SessionToken,
    [int]$DashboardId,
    [int]$CollectionId,
    [string]$Name,
    [string]$Description,
    [object[]]$Parameters
  )

  $body = @{
    name = $Name
    description = $Description
    collection_id = $CollectionId
    parameters = $Parameters
  }

  Invoke-Mb -Method Put -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60 | Out-Null
}

function Try-UpdateDashboardParameters {
  param(
    [string]$SessionToken,
    [int]$DashboardId,
    [int]$CollectionId,
    [string]$Name,
    [string]$Description,
    [object[]]$Parameters
  )

  try {
    Update-DashboardParameters -SessionToken $SessionToken -DashboardId $DashboardId -CollectionId $CollectionId -Name $Name -Description $Description -Parameters $Parameters
    return $true
  } catch {
    Write-Host ("Dashboard parameter update rejected by Metabase; falling back.\n" + $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }
}

function Set-DashboardCards {
  param(
    [string]$SessionToken,
    [int]$DashboardId,
    [object[]]$Cards
  )

  $body = @{ cards = $Cards }
  Invoke-Mb -Method Put -Path ("/api/dashboard/{0}/cards" -f $DashboardId) -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60 | Out-Null
}

function Detect-AppUuidWithDocker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker not available on PATH; cannot autodetect AppUuid. Provide -AppUuid explicitly.'
  }

  $out = docker exec sb-postgres psql -U sb -d sb_analytics -t -A -c "SELECT app_uuid FROM device_hourly_presence GROUP BY app_uuid ORDER BY count(*) DESC LIMIT 1;"
  $val = ([string]($out | Select-Object -First 1)).Trim()
  if ($val -notmatch '^[0-9a-fA-F-]{36}$') {
    throw "Could not autodetect app_uuid from docker/psql output: '$val'"
  }
  return $val
}

function Get-DbMetadata([string]$SessionToken, [int]$DatabaseId) {
  return (Invoke-Mb -Method Get -Path ("/api/database/{0}/metadata" -f $DatabaseId) -SessionToken $SessionToken -TimeoutSec 120)
}

function Get-FieldId {
  param(
    [Parameter(Mandatory = $true)]
    [object]$DbMetadata,

    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [string]$FieldName,

    [string]$SchemaName = 'public'
  )

  $table = @($DbMetadata.tables) | Where-Object { $_.schema -eq $SchemaName -and $_.name -eq $TableName } | Select-Object -First 1
  if (-not $table) { throw "Table not found in Metabase metadata: ${SchemaName}.${TableName}" }
  $field = @($table.fields) | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1
  if (-not $field) { throw "Field not found in Metabase metadata: ${SchemaName}.${TableName}.${FieldName}" }
  return [int]$field.id
}

function New-FieldFilterTemplateTags {
  param(
    [Parameter(Mandatory = $true)]
    [int]$AppUuidFieldId,

    [Parameter(Mandatory = $true)]
    [int]$DateFieldId
  )

  $tags = @{}

  $tags.app_uuid = @{
    id = ([guid]::NewGuid().ToString())
    name = 'app_uuid'
    'display-name' = 'App'
    type = 'dimension'
    dimension = @('field', $AppUuidFieldId, $null)
    'widget-type' = 'category'
  }

  $tags.date_range = @{
    id = ([guid]::NewGuid().ToString())
    name = 'date_range'
    'display-name' = 'Date range'
    type = 'dimension'
    dimension = @('field', $DateFieldId, $null)
    'widget-type' = 'date/range'
  }

  return $tags
}

Write-Host "Creating starter dashboard in Metabase -> $MetabaseUrl" -ForegroundColor Cyan
Wait-ForMetabase

if ([string]::IsNullOrWhiteSpace($AppUuid)) {
  if ($UseDockerAutodetect) {
    $AppUuid = Detect-AppUuidWithDocker
    Write-Host "Auto-detected app_uuid: $AppUuid" -ForegroundColor Green
  } else {
    throw 'AppUuid is required. Provide -AppUuid or use -UseDockerAutodetect.'
  }
}

$token = New-MetabaseSessionToken
Write-Host 'Authenticated to Metabase.' -ForegroundColor DarkGray
$dbId = Get-DatabaseId -SessionToken $token
Write-Host ("Using Metabase DB id={0}" -f $dbId) -ForegroundColor DarkGray
$meta = Get-DbMetadata -SessionToken $token -DatabaseId $dbId
$collectionId = Ensure-Collection -SessionToken $token -Name 'SmartBuket Analytics'
Write-Host ("Using collection id={0}" -f $collectionId) -ForegroundColor DarkGray

$dashName = 'SmartBuket Analytics - Overview'
$dashDesc = 'Overview dashboard with filters (app + date range): DAH/UAH, top places, H3 density, licensing.'

if ($ArchiveDuplicateDashboards) {
  try {
    $kept = Archive-DuplicateDashboardsByName -SessionToken $token -Name $dashName -CollectionId $collectionId
    if ($kept) {
      Write-Host ("Archived older duplicate dashboards. Keeping id={0}." -f $kept) -ForegroundColor Green
    }
  } catch {
    Write-Host ("Could not archive duplicate dashboards (non-fatal): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

$dashId = Ensure-Dashboard -SessionToken $token -CollectionId $collectionId -Name $dashName -Description $dashDesc
Write-Host ("Using dashboard id={0}" -f $dashId) -ForegroundColor DarkGray

$existingDash = $null
try { $existingDash = Get-Dashboard -SessionToken $token -DashboardId $dashId } catch { $existingDash = $null }

$paramAppId = $null
$paramDateId = $null
if ($existingDash -and $existingDash.parameters) {
  $pApp = @($existingDash.parameters) | Where-Object { $_.slug -eq 'app_uuid' } | Select-Object -First 1
  $pDate = @($existingDash.parameters) | Where-Object { $_.slug -eq 'date_range' } | Select-Object -First 1
  if ($pApp -and $pApp.id) { $paramAppId = [string]$pApp.id }
  if ($pDate -and $pDate.id) { $paramDateId = [string]$pDate.id }
}
if ([string]::IsNullOrWhiteSpace($paramAppId)) { $paramAppId = ([guid]::NewGuid().ToString()) }
if ([string]::IsNullOrWhiteSpace($paramDateId)) { $paramDateId = ([guid]::NewGuid().ToString()) }

# Cards
$sqlDah = @"
SELECT
  hour_bucket AS hour,
  COUNT(*)::bigint AS dah
FROM device_hourly_presence
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1
ORDER BY 1;
"@

$sqlDahAvg = @"
WITH per_hour AS (
  SELECT hour_bucket, COUNT(*)::bigint AS dah
  FROM device_hourly_presence
  WHERE 1=1
  [[AND {{app_uuid}}]]
  [[AND {{date_range}}]]
  GROUP BY 1
)
SELECT COALESCE(AVG(dah), 0)::numeric(12,2) AS value
FROM per_hour;
"@

$sqlDahPeak = @"
WITH per_hour AS (
  SELECT hour_bucket, COUNT(*)::bigint AS dah
  FROM device_hourly_presence
  WHERE 1=1
  [[AND {{app_uuid}}]]
  [[AND {{date_range}}]]
  GROUP BY 1
)
SELECT COALESCE(MAX(dah), 0)::bigint AS value
FROM per_hour;
"@

$sqlUah = @"
SELECT
  hour_bucket AS hour,
  COUNT(*)::bigint AS uah
FROM user_hourly_presence
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1
ORDER BY 1;
"@

$sqlUahAvg = @"
WITH per_hour AS (
  SELECT hour_bucket, COUNT(*)::bigint AS uah
  FROM user_hourly_presence
  WHERE 1=1
  [[AND {{app_uuid}}]]
  [[AND {{date_range}}]]
  GROUP BY 1
)
SELECT COALESCE(AVG(uah), 0)::numeric(12,2) AS value
FROM per_hour;
"@

$sqlUahPeak = @"
WITH per_hour AS (
  SELECT hour_bucket, COUNT(*)::bigint AS uah
  FROM user_hourly_presence
  WHERE 1=1
  [[AND {{app_uuid}}]]
  [[AND {{date_range}}]]
  GROUP BY 1
)
SELECT COALESCE(MAX(uah), 0)::bigint AS value
FROM per_hour;
"@

$sqlTopPlaces = @"
SELECT
  aph.place_id,
  p.name,
  p.place_type,
  SUM(aph.users_count)::bigint AS users,
  SUM(aph.devices_count)::bigint AS devices
FROM agg_place_hourly aph
JOIN places p ON p.place_id = aph.place_id
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1,2,3
ORDER BY users DESC
LIMIT 15;
"@

$sqlH3 = @"
SELECT
  h3_r9,
  SUM(users_count)::bigint   AS users,
  SUM(devices_count)::bigint AS devices
FROM agg_h3_r9_hourly
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1
ORDER BY users DESC
LIMIT 2000;
"@

$sqlPlacesMap = @"
SELECT
  aph.place_id,
  p.name,
  p.place_type,
  ST_Y(ST_Centroid(p.geofence))::double precision AS latitude,
  ST_X(ST_Centroid(p.geofence))::double precision AS longitude,
  SUM(aph.users_count)::bigint   AS users,
  SUM(aph.devices_count)::bigint AS devices
FROM agg_place_hourly aph
JOIN places p ON p.place_id = aph.place_id
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1,2,3,4,5
ORDER BY users DESC
LIMIT 500;
"@

$sqlLicenses = @"
SELECT
  license_status,
  plan_type,
  COUNT(*)::bigint AS users
FROM license_state
WHERE 1=1
[[AND {{app_uuid}}]]
[[AND {{date_range}}]]
GROUP BY 1,2
ORDER BY users DESC;
"@

# Field IDs (used both for card template-tags and for better dashboard filter UX)
$dahAppField = Get-FieldId -DbMetadata $meta -TableName 'device_hourly_presence' -FieldName 'app_uuid'
$dahDateField = Get-FieldId -DbMetadata $meta -TableName 'device_hourly_presence' -FieldName 'hour_bucket'
$uahAppField = Get-FieldId -DbMetadata $meta -TableName 'user_hourly_presence' -FieldName 'app_uuid'
$uahDateField = Get-FieldId -DbMetadata $meta -TableName 'user_hourly_presence' -FieldName 'hour_bucket'
$topAppField = Get-FieldId -DbMetadata $meta -TableName 'agg_place_hourly' -FieldName 'app_uuid'
$topDateField = Get-FieldId -DbMetadata $meta -TableName 'agg_place_hourly' -FieldName 'hour_bucket'
$h3AppField = Get-FieldId -DbMetadata $meta -TableName 'agg_h3_r9_hourly' -FieldName 'app_uuid'
$h3DateField = Get-FieldId -DbMetadata $meta -TableName 'agg_h3_r9_hourly' -FieldName 'hour_bucket'
$licAppField = Get-FieldId -DbMetadata $meta -TableName 'license_state' -FieldName 'app_uuid'
$licDateField = Get-FieldId -DbMetadata $meta -TableName 'license_state' -FieldName 'updated_at'

# Dashboard filters
# Note: this Metabase build only supports values_source_type = static-list or card.
# We create a helper card that returns distinct app_uuid values, and bind the dashboard parameter to that card.
$sqlAppsList = @"
SELECT
  app_uuid
FROM device_hourly_presence
GROUP BY 1
ORDER BY COUNT(*) DESC;
"@

$cardApps = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'Apps - distinct app_uuid' -Display 'table' -Sql $sqlAppsList
Write-Host ("Ensured helper card: Apps (id={0})" -f $cardApps) -ForegroundColor DarkGray

$dashParamsCardSource = @(
  @{
    id = $paramAppId
    name = 'App'
    slug = 'app_uuid'
    type = 'category'
    default = $AppUuid
    values_source_type = 'card'
    values_query_type = 'list'
    values_source_config = @{ card_id = $cardApps }
  },
  @{
    id = $paramDateId
    name = 'Date range'
    slug = 'date_range'
    type = 'date/range'
    default = $DateRangeDefault
  }
)

if (-not (Try-UpdateDashboardParameters -SessionToken $token -DashboardId $dashId -CollectionId $collectionId -Name $dashName -Description $dashDesc -Parameters $dashParamsCardSource)) {
  # Some Metabase versions require explicit value_field/label_field.
  $dashParamsCardSource2 = @(
    @{
      id = $paramAppId
      name = 'App'
      slug = 'app_uuid'
      type = 'category'
      default = $AppUuid
      values_source_type = 'card'
      values_query_type = 'list'
      values_source_config = @{
        card_id = $cardApps
        value_field = @('field', $dahAppField, $null)
        label_field = @('field', $dahAppField, $null)
      }
    },
    @{
      id = $paramDateId
      name = 'Date range'
      slug = 'date_range'
      type = 'date/range'
      default = $DateRangeDefault
    }
  )

  if (-not (Try-UpdateDashboardParameters -SessionToken $token -DashboardId $dashId -CollectionId $collectionId -Name $dashName -Description $dashDesc -Parameters $dashParamsCardSource2)) {
    $dashParamsFallback = @(
      @{ id = $paramAppId; name = 'App'; slug = 'app_uuid'; type = 'category'; default = $AppUuid },
      @{ id = $paramDateId; name = 'Date range'; slug = 'date_range'; type = 'date/range' }
    )
    Update-DashboardParameters -SessionToken $token -DashboardId $dashId -CollectionId $collectionId -Name $dashName -Description $dashDesc -Parameters $dashParamsFallback
  }
}

$tagsDah = New-FieldFilterTemplateTags -AppUuidFieldId $dahAppField -DateFieldId $dahDateField
$tagsUah = New-FieldFilterTemplateTags -AppUuidFieldId $uahAppField -DateFieldId $uahDateField
$tagsTop = New-FieldFilterTemplateTags -AppUuidFieldId $topAppField -DateFieldId $topDateField
$tagsH3  = New-FieldFilterTemplateTags -AppUuidFieldId $h3AppField -DateFieldId $h3DateField
$tagsLic = New-FieldFilterTemplateTags -AppUuidFieldId $licAppField -DateFieldId $licDateField

$cardDahAvg  = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'DAH avg'  -Display 'scalar' -Sql $sqlDahAvg  -TemplateTags $tagsDah
$null = Write-Host ("Created card: DAH avg (id={0})" -f $cardDahAvg) -ForegroundColor DarkGray
$cardDahPeak = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'DAH peak' -Display 'scalar' -Sql $sqlDahPeak -TemplateTags $tagsDah
$null = Write-Host ("Created card: DAH peak (id={0})" -f $cardDahPeak) -ForegroundColor DarkGray
$cardUahAvg  = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'UAH avg'  -Display 'scalar' -Sql $sqlUahAvg  -TemplateTags $tagsUah
$null = Write-Host ("Created card: UAH avg (id={0})" -f $cardUahAvg) -ForegroundColor DarkGray
$cardUahPeak = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'UAH peak' -Display 'scalar' -Sql $sqlUahPeak -TemplateTags $tagsUah
$null = Write-Host ("Created card: UAH peak (id={0})" -f $cardUahPeak) -ForegroundColor DarkGray

$cardDah = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'DAH (devices) - hourly' -Display 'line' -Sql $sqlDah -TemplateTags $tagsDah
$null = Write-Host ("Created card: DAH (id={0})" -f $cardDah) -ForegroundColor DarkGray
$cardUah = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'UAH (users) - hourly'   -Display 'line' -Sql $sqlUah -TemplateTags $tagsUah
$null = Write-Host ("Created card: UAH (id={0})" -f $cardUah) -ForegroundColor DarkGray
$cardTop = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'Top places'            -Display 'bar'  -Sql $sqlTopPlaces -TemplateTags $tagsTop
$null = Write-Host ("Created card: Top places (id={0})" -f $cardTop) -ForegroundColor DarkGray
$mapViz = @{
  'map.type' = 'pin'
  'map.latitude_column' = 'latitude'
  'map.longitude_column' = 'longitude'
  'map.metric' = 'users'
}
$cardMap = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'Places map (users/devices)' -Display 'map' -Sql $sqlPlacesMap -TemplateTags $tagsTop -VisualizationSettings $mapViz
$null = Write-Host ("Created card: Places map (id={0})" -f $cardMap) -ForegroundColor DarkGray
$cardH3  = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'H3 r9 density'         -Display 'table' -Sql $sqlH3 -TemplateTags $tagsH3
$null = Write-Host ("Created card: H3 (id={0})" -f $cardH3) -ForegroundColor DarkGray
$cardLic = Ensure-Card -SessionToken $token -CollectionId $collectionId -DatabaseId $dbId -Name 'Licenses - by status/plan'         -Display 'pie'  -Sql $sqlLicenses -TemplateTags $tagsLic
$null = Write-Host ("Created card: Licenses (id={0})" -f $cardLic) -ForegroundColor DarkGray

# Layout (24-column grid)
# Metabase expects snake_case keys and requires an `id` per dashcard; new ones can use temporary negative ids.
$dashcards = @(
  @{ id = -1; card_id = $cardDahAvg;  row = 0;  col = 0;  size_x = 6;  size_y = 4; parameter_mappings = @(
      @{ parameter_id = $paramAppId;  card_id = $cardDahAvg;  target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardDahAvg;  target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -2; card_id = $cardDahPeak; row = 0;  col = 6;  size_x = 6;  size_y = 4; parameter_mappings = @(
      @{ parameter_id = $paramAppId;  card_id = $cardDahPeak; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardDahPeak; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -3; card_id = $cardUahAvg;  row = 0;  col = 12; size_x = 6;  size_y = 4; parameter_mappings = @(
      @{ parameter_id = $paramAppId;  card_id = $cardUahAvg;  target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardUahAvg;  target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -4; card_id = $cardUahPeak; row = 0;  col = 18; size_x = 6;  size_y = 4; parameter_mappings = @(
      @{ parameter_id = $paramAppId;  card_id = $cardUahPeak; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardUahPeak; target = @('dimension', @('template-tag','date_range')) }
    ) },

  @{ id = -5; card_id = $cardDah; row = 4;  col = 0;  size_x = 12; size_y = 6;  parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardDah; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardDah; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -6; card_id = $cardUah; row = 4;  col = 12; size_x = 12; size_y = 6;  parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardUah; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardUah; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -7; card_id = $cardTop; row = 10; col = 0;  size_x = 12; size_y = 8;  parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardTop; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardTop; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -8; card_id = $cardLic; row = 10; col = 12; size_x = 12; size_y = 8;  parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardLic; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardLic; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -9;  card_id = $cardMap; row = 18; col = 0;  size_x = 24; size_y = 10; parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardMap; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardMap; target = @('dimension', @('template-tag','date_range')) }
    ) },
  @{ id = -10; card_id = $cardH3;  row = 28; col = 0;  size_x = 24; size_y = 10; parameter_mappings = @(
      @{ parameter_id = $paramAppId; card_id = $cardH3; target = @('dimension', @('template-tag','app_uuid')) },
      @{ parameter_id = $paramDateId; card_id = $cardH3; target = @('dimension', @('template-tag','date_range')) }
    ) }
)

Set-DashboardCards -SessionToken $token -DashboardId $dashId -Cards $dashcards

Write-Host 'Starter dashboard created.' -ForegroundColor Green
Write-Host ("Dashboard: {0}/dashboard/{1}" -f $MetabaseUrl, $dashId) -ForegroundColor Green
Write-Host ("Collection: {0}/collection/{1}" -f $MetabaseUrl, $collectionId) -ForegroundColor DarkGray
