param(
  [string]$MetabaseUrl = 'http://localhost:3001',
  [string]$Email = 'admin@smartbuket.com',
  [string]$Password = '',
  [string]$CollectionName = 'SmartBuket Analytics',
  [string]$DashboardName = 'SmartBuket Analytics - Overview',
  [int]$KeepDashboardId = 0,
  [switch]$DryRun
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

  if ($null -eq $BodyObject) {
    return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -TimeoutSec $TimeoutSec)
  }

  $json = $BodyObject | ConvertTo-Json -Depth 20 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec)
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

  $resp = Invoke-Mb -Method Get -Path $path -SessionToken $SessionToken -TimeoutSec 60
  if ($null -ne $resp -and $null -ne $resp.data) {
    return @($resp.data)
  }
  return @($resp)
}

function Get-CollectionId([string]$SessionToken, [string]$Name) {
  $cols = Invoke-Mb -Method Get -Path '/api/collection' -SessionToken $SessionToken -TimeoutSec 60
  $existing = @($cols) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $existing) { throw "Collection not found: $Name" }
  return [int]$existing.id
}

function ConvertTo-DateTime([object]$v) {
  if ($null -eq $v) { return [datetime]::MinValue }
  try { return [datetime]::Parse([string]$v) } catch { return [datetime]::MinValue }
}

function Set-DashboardArchived([string]$SessionToken, [int]$DashboardId) {
  $d = Invoke-Mb -Method Get -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -TimeoutSec 60

  $body = @{
    name = $d.name
    description = $d.description
    collection_id = $d.collection_id
    parameters = @($d.parameters)
    archived = $true
  }

  if ($DryRun) {
    Write-Host ("[DryRun] Would archive dashboard id={0} name='{1}'" -f $DashboardId, $d.name) -ForegroundColor Yellow
    return
  }

  Invoke-Mb -Method Put -Path ("/api/dashboard/{0}" -f $DashboardId) -SessionToken $SessionToken -BodyObject $body -TimeoutSec 60 | Out-Null
}

Write-Host "Metabase archive duplicates -> $MetabaseUrl" -ForegroundColor Cyan
Wait-ForMetabase
$tok = New-MetabaseSessionToken
$collectionId = Get-CollectionId -SessionToken $tok -Name $CollectionName

$dashMatches = Search-Mb -SessionToken $tok -Query $DashboardName -Models @('dashboard') |
  Where-Object {
    $_.model -eq 'dashboard' -and $_.name -eq $DashboardName -and $_.archived -ne $true -and $_.collection -and ([int]$_.collection.id -eq $collectionId)
  }

if (-not $dashMatches -or @($dashMatches).Count -le 1) {
  Write-Host 'No duplicate dashboards to archive.' -ForegroundColor Green
  exit 0
}

$keepId = $KeepDashboardId
if ($keepId -le 0) {
  $keepId = [int](@($dashMatches) | Sort-Object @{ Expression = { ConvertTo-DateTime $_.updated_at }; Descending = $true }, @{ Expression = { ConvertTo-DateTime $_.created_at }; Descending = $true } | Select-Object -First 1).id
}

Write-Host ("Found {0} dashboards named '{1}' in collection '{2}'. Keeping id={3}." -f @($dashMatches).Count, $DashboardName, $CollectionName, $keepId) -ForegroundColor Cyan

$toArchive = @($dashMatches | Where-Object { [int]$_.id -ne $keepId })
foreach ($d in $toArchive) {
  Write-Host ("Archiving dashboard id={0} (updated_at={1})" -f $d.id, $d.updated_at) -ForegroundColor Yellow
  Set-DashboardArchived -SessionToken $tok -DashboardId ([int]$d.id)
}

Write-Host ("Done. Archived {0} dashboards." -f $toArchive.Count) -ForegroundColor Green
