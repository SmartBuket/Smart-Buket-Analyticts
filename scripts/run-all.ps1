param(
  [switch]$UseDockerQueryApi,
  [switch]$UseDockerIngestApi,
  [switch]$UseDockerRecoApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$python = Join-Path $root '.venv\Scripts\python.exe'
$compose = Join-Path $root 'infra\docker-compose.yml'
$logsDir = Join-Path $PSScriptRoot 'logs'
$runner = Join-Path $PSScriptRoot '_run-service.ps1'

$portsToFree = @(8001, 8002, 8003)
$serviceNames = @('sb-ingest','sb-query','sb-reco','sb-processor','sb-outbox')

$envCommon = @{
  'SB_RABBITMQ_URL'    = 'amqp://guest:guest@localhost:5672/'
  'SB_POSTGRES_DSN'    = 'postgresql+psycopg://sb:sb@localhost:15432/sb_analytics'
  'PYTHONUNBUFFERED'   = '1'
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'

function Assert-FileExists([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required file: $path"
  }
}

function Escape-SingleQuoted([string]$value) {
  return ($value -replace "'", "''")
}

function Stop-SBProcessesFromPidFiles {
  foreach ($name in $serviceNames) {
    $pidPath = Join-Path $logsDir ("$name.pid")
    if (Test-Path -LiteralPath $pidPath) {
      $pidText = (Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
      if ($pidText -match '^\d+$') {
        $procId = [int]$pidText
        try {
          Write-Host "Stopping $name PID $procId" -ForegroundColor Yellow
          Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        } catch {}
      }
      try { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

function Free-Port([int]$port) {
  $listeners = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
  foreach ($l in $listeners) {
    try {
      Write-Host "Stopping PID $($l.OwningProcess) on port $port" -ForegroundColor Yellow
      Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
    } catch {}
  }
}

function Ensure-InfraUp {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker is not available on PATH'
  }

  docker info | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Docker engine is not reachable. Start Docker Desktop (or ensure the Docker service is running) and retry.'
  }

  $needed = @('sb-postgres','sb-rabbitmq','sb-pgadmin','sb-metabase')
  $running = @(docker ps --format '{{.Names}}')
  $missing = @($needed | Where-Object { $running -notcontains $_ })

  if ($missing.Count -gt 0) {
    Write-Host "Infra containers missing: $($missing -join ', '). Starting compose..." -ForegroundColor Cyan
    Push-Location $root
    try {
      docker compose -f $compose up -d | Out-Null
    } finally {
      Pop-Location
    }
  } else {
    Write-Host 'Infra containers already running.' -ForegroundColor Green
  }
}

function Ensure-DockerQueryApiUp {
  Push-Location $root
  try {
    docker compose -f $compose --profile beta up -d query-api | Out-Null
  } finally {
    Pop-Location
  }
}

function Ensure-DockerIngestApiUp {
  Push-Location $root
  try {
    docker compose -f $compose --profile beta up -d ingest-api | Out-Null
  } finally {
    Pop-Location
  }
}

function Ensure-DockerRecoApiUp {
  Push-Location $root
  try {
    docker compose -f $compose --profile beta up -d reco-api | Out-Null
  } finally {
    Pop-Location
  }
}

function Ensure-MetabaseAppDb {
  # Metabase is configured to use Postgres as its application DB.
  # `infra/init.sql` will only run on a fresh volume, so we also ensure it here.

  # Postgres can take a few seconds to accept connections after container start.
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    docker exec sb-postgres pg_isready -U sb -d postgres | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $ready = $true
      break
    }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) {
    throw 'Postgres is not ready yet (sb-postgres). Try again in a few seconds, or check container logs: docker logs sb-postgres'
  }

  $roleExists = (docker exec -i sb-postgres psql -U sb -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='sb_metabase'" | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($roleExists)) {
    Write-Host 'Creating Postgres role sb_metabase...' -ForegroundColor Cyan
    docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE sb_metabase LOGIN PASSWORD 'sb_metabase';" | Out-Null
  }

  $dbExists = (docker exec -i sb-postgres psql -U sb -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='sb_metabase'" | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($dbExists)) {
    Write-Host 'Creating Postgres database sb_metabase...' -ForegroundColor Cyan
    docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE sb_metabase OWNER sb_metabase;" | Out-Null
  }

  # If metabase was started before the DB existed, restart it.
  $mbRunning = @(docker ps --format '{{.Names}}') -contains 'sb-metabase'
  if (-not $mbRunning) {
    Write-Host 'Restarting Metabase (app DB ready)...' -ForegroundColor Cyan
    Push-Location $root
    try {
      docker compose -f $compose up -d --force-recreate metabase | Out-Null
    } finally {
      Pop-Location
    }
  }
}

function Ensure-RabbitMqPolicies {
  # We publish `sb.events.raw` but (by design) may not have a consumer in the MVP.
  # Cap/TTL the raw queue to prevent unbounded growth.
  $policyName = 'sb_raw_queue_limits'

  $sec = ConvertTo-SecureString 'guest' -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential('guest', $sec)
  $uri = "http://localhost:15672/api/policies/%2F/$policyName"

    $body = (@{
        pattern = '^sb\\.events\\.(raw|session|screen|ui|system)\\.q$'
      definition = @{
        'message-ttl' = 86400000
        'max-length'  = 100000
        overflow      = 'drop-head'
      }
      priority = 0
      'apply-to' = 'queues'
    } | ConvertTo-Json -Depth 5)

  for ($i = 0; $i -lt 30; $i++) {
    try {
      Invoke-RestMethod -Method Put -Uri $uri -Credential $cred -Body $body -ContentType 'application/json' | Out-Null
      Write-Host "RabbitMQ policy applied: $policyName" -ForegroundColor Green
      return
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }

  Write-Warning 'Could not apply RabbitMQ policies (management API not ready). Continuing anyway.'
}

function Quote-Arg([string]$value) {
  if ($null -eq $value) { return '""' }
  $escaped = $value -replace '"', '\\"'
  return '"' + $escaped + '"'
}

function Start-ServiceProcess(
  [string]$name,
  [string]$workDir,
  [string[]]$pythonArgs,
  [string]$rabbitMqUrl = '',
  [string]$processorGroupId = ''
) {
  $logPath = Join-Path $logsDir ("$name.$runId.out.log")
  $errPath = Join-Path $logsDir ("$name.$runId.err.log")
  $pidPath = Join-Path $logsDir ("$name.pid")
  "`n==== $(Get-Date -Format o) ====" | Out-File -FilePath $logPath -Append -Encoding utf8
  "`n==== $(Get-Date -Format o) ====" | Out-File -FilePath $errPath -Append -Encoding utf8

  $argLine = ($pythonArgs -join '||')

  $parts = @(
      '-NoProfile',
      '-ExecutionPolicy','Bypass',
      '-File', $runner,
      '-WorkDir', $workDir,
      '-PythonPath', $python,
      '-RabbitMqUrl', $rabbitMqUrl,
      '-ProcessorGroupId', $processorGroupId,
      '-PostgresDsn', $envCommon['SB_POSTGRES_DSN'],
      '-ArgLine', $argLine
    )

  $argumentString = ($parts | ForEach-Object { Quote-Arg ([string]$_) }) -join ' '

  $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argumentString -RedirectStandardOutput $logPath -RedirectStandardError $errPath -PassThru

  $proc.Id | Out-File -FilePath $pidPath -Encoding ascii -Force
}

function Wait-HttpOk([string]$url, [int]$timeoutSeconds = 20) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  return $false
}

Assert-FileExists $python
Assert-FileExists $compose
Assert-FileExists $runner

if (-not (Test-Path -LiteralPath $logsDir)) {
  New-Item -ItemType Directory -Path $logsDir | Out-Null
}

$runId | Out-File -LiteralPath (Join-Path $logsDir 'latest-run.txt') -Encoding ascii -Force

Write-Host '1) Ensuring infra is up...' -ForegroundColor Cyan
Ensure-InfraUp

Write-Host '1a) Ensuring Metabase application DB...' -ForegroundColor Cyan
Ensure-MetabaseAppDb

Write-Host '1b) Ensuring RabbitMQ policies...' -ForegroundColor Cyan
Ensure-RabbitMqPolicies

Write-Host '2) Stopping existing SmartBuket processes (pid files)...' -ForegroundColor Cyan
Stop-SBProcessesFromPidFiles

Write-Host '3) Freeing API ports...' -ForegroundColor Cyan
$ports = $portsToFree
if ($UseDockerQueryApi) {
  # Port 8002 may be bound by the Docker query-api container.
  # Freeing it here can kill the Docker port proxy process.
  $ports = @($portsToFree | Where-Object { $_ -ne 8002 })
}
if ($UseDockerIngestApi) {
  # Port 8001 may be bound by the Docker ingest-api container.
  $ports = @($ports | Where-Object { $_ -ne 8001 })
}
if ($UseDockerRecoApi) {
  # Port 8003 may be bound by the Docker reco-api container.
  $ports = @($ports | Where-Object { $_ -ne 8003 })
}
foreach ($p in $ports) { Free-Port $p }

Write-Host '4) Starting services...' -ForegroundColor Cyan
if ($UseDockerIngestApi) {
  Write-Host 'Starting ingest-api via Docker (profile beta)...' -ForegroundColor Cyan
  Ensure-DockerIngestApiUp
} else {
  Start-ServiceProcess -name 'sb-ingest' -workDir (Join-Path $root 'services\ingest-api') -pythonArgs @('-u','-m','uvicorn','app.main:app','--host','0.0.0.0','--port','8001') -rabbitMqUrl $envCommon['SB_RABBITMQ_URL']
}
if ($UseDockerQueryApi) {
  Write-Host 'Starting query-api via Docker (profile beta)...' -ForegroundColor Cyan
  Ensure-DockerQueryApiUp
} else {
  Start-ServiceProcess -name 'sb-query'  -workDir (Join-Path $root 'services\query-api')  -pythonArgs @('-u','-m','uvicorn','app.main:app','--host','0.0.0.0','--port','8002')
}
if ($UseDockerRecoApi) {
  Write-Host 'Starting reco-api via Docker (profile beta)...' -ForegroundColor Cyan
  Ensure-DockerRecoApiUp
} else {
  Start-ServiceProcess -name 'sb-reco'   -workDir (Join-Path $root 'services\reco-api')   -pythonArgs @('-u','-m','uvicorn','app.main:app','--host','0.0.0.0','--port','8003')
}
Start-ServiceProcess -name 'sb-processor' -workDir (Join-Path $root 'services\processor') -pythonArgs @('-u','app\worker.py') -rabbitMqUrl $envCommon['SB_RABBITMQ_URL'] -processorGroupId 'sb-processor-c360v1'
Start-ServiceProcess -name 'sb-outbox' -workDir (Join-Path $root 'services\outbox-publisher') -pythonArgs @('-u','app\worker.py') -rabbitMqUrl $envCommon['SB_RABBITMQ_URL']

Write-Host '5) Waiting for health endpoints...' -ForegroundColor Cyan
$ok1 = Wait-HttpOk 'http://localhost:8001/health' 25
$ok2 = Wait-HttpOk 'http://localhost:8002/health' 25
$ok3 = Wait-HttpOk 'http://localhost:8003/health' 25

Write-Host ''
Write-Host 'Status:' -ForegroundColor Cyan
Get-ChildItem -LiteralPath $logsDir -Filter 'sb-*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
  $name = $_.BaseName
  $procId = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 1)
  [PSCustomObject]@{ Name = $name; PID = $procId }
} | Format-Table -AutoSize

Write-Host ''
Write-Host ("Ingest docs: http://localhost:8001/docs (health=$ok1)")
Write-Host ("Query  docs: http://localhost:8002/docs (health=$ok2)")
Write-Host ("Reco   docs: http://localhost:8003/docs (health=$ok3)")
Write-Host 'RabbitMQ UI: http://localhost:15672 (guest/guest)'
Write-Host 'pgAdmin:     http://localhost:5050'
Write-Host ''
Write-Host ('Logs: ' + $logsDir) -ForegroundColor Green
Write-Host ('RunId: ' + $runId) -ForegroundColor Green
Write-Host 'To tail logs:'
Write-Host ("  Get-Content .\\scripts\\logs\\sb-ingest.$runId.out.log -Wait")
Write-Host ("  Get-Content .\\scripts\\logs\\sb-ingest.$runId.err.log -Wait")
Write-Host ("  Get-Content .\\scripts\\logs\\sb-processor.$runId.out.log -Wait")
Write-Host ("  Get-Content .\\scripts\\logs\\sb-processor.$runId.err.log -Wait")
Write-Host ''
Write-Host 'Status helper:'
Write-Host '  .\scripts\status.ps1'
