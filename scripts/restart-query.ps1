Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$python = Join-Path $root '.venv\Scripts\python.exe'
$runner = Join-Path $PSScriptRoot '_run-service.ps1'
$logsDir = Join-Path $PSScriptRoot 'logs'

function Assert-FileExists([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required file: $path"
  }
}

function Free-Port([int]$port) {
  $listeners = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
  foreach ($l in $listeners) {
    try {
      Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
    } catch {}
  }
}

function Wait-HttpOk([string]$url, [int]$timeoutSeconds = 20) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
    } catch {
      Start-Sleep -Milliseconds 400
    }
  }
  return $false
}

Assert-FileExists $python
Assert-FileExists $runner
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

$pidPath = Join-Path $logsDir 'sb-query.pid'
if (Test-Path -LiteralPath $pidPath) {
  $pidText = (Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($pidText -match '^\d+$') {
    try { Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue } catch {}
  }
  try { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue } catch {}
}

Free-Port 8002

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logsDir ("sb-query.$runId.out.log")
$errPath = Join-Path $logsDir ("sb-query.$runId.err.log")
"`n==== $(Get-Date -Format o) ==== (restart-query)" | Out-File -FilePath $logPath -Append -Encoding utf8
"`n==== $(Get-Date -Format o) ==== (restart-query)" | Out-File -FilePath $errPath -Append -Encoding utf8

$workDir = Join-Path $root 'services\query-api'
$env:SB_POSTGRES_DSN = 'postgresql+psycopg://sb:sb@localhost:15432/sb_analytics'

# Log which module path would be imported (helps detect stale/incorrect PYTHONPATH/app-dir)
try {
  $spec = & $python -c "import importlib.util; s=importlib.util.find_spec('app.main'); print(s.origin if s else 'NOT_FOUND')" 2>$null
  if ($spec) {
    ("app.main spec.origin: {0}" -f ($spec | Select-Object -First 1)) | Out-File -FilePath $logPath -Append -Encoding utf8
  }
} catch {
  # ignore
}

$pythonArgs = @(
  '-u','-m','uvicorn','app.main:app',
  '--app-dir', $workDir,
  '--host','0.0.0.0',
  '--port','8002'
)
$argLine = ($pythonArgs -join '||')

$argumentList = @(
  '-NoProfile',
  '-ExecutionPolicy','Bypass',
  '-File', $runner,
  '-WorkDir', $workDir,
  '-PythonPath', $python,
  '-PostgresDsn', $env:SB_POSTGRES_DSN,
  '-ArgLine', $argLine
)

$proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ($argumentList | ForEach-Object { '"' + ($_ -replace '"','\\"') + '"' } -join ' ') -RedirectStandardOutput $logPath -RedirectStandardError $errPath -PassThru
$proc.Id | Out-File -FilePath $pidPath -Encoding ascii -Force

$ok = Wait-HttpOk 'http://localhost:8002/health' 25
if (-not $ok) {
  Write-Host 'Query API did not become healthy on :8002' -ForegroundColor Red
  Write-Host "Check logs: $logPath and $errPath" -ForegroundColor Yellow
  exit 2
}

$o = Invoke-RestMethod -Uri 'http://localhost:8002/openapi.json'
$paths = @($o.paths.PSObject.Properties.Name)
$agg = $paths | Where-Object { $_ -like '/v1/aggregates/*' } | Sort-Object
if ($agg.Count -eq 0) {
  Write-Host 'WARNING: query-api OpenAPI still has NO /v1/aggregates/* routes' -ForegroundColor Yellow
  Write-Host 'This indicates the running process is not the updated code.' -ForegroundColor Yellow
} else {
  Write-Host 'OK: aggregates routes are present in OpenAPI:' -ForegroundColor Green
  $agg | ForEach-Object { Write-Host ('  ' + $_) }
}

Write-Host ''
Write-Host ('PID: ' + $proc.Id) -ForegroundColor Cyan
Write-Host ('Logs: ' + $logPath) -ForegroundColor Cyan
