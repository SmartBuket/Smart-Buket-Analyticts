param(
  [switch]$DownInfra
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$logsDir = Join-Path $PSScriptRoot 'logs'
$root = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $root 'infra\docker-compose.yml'
$serviceNames = @('sb-ingest','sb-query','sb-reco','sb-processor')
$portsToFree = @(8001,8002,8003)

function Stop-SBProcessesFromPidFiles {
  foreach ($name in $serviceNames) {
    $pidPath = Join-Path $logsDir ("$name.pid")
    if (Test-Path -LiteralPath $pidPath) {
      $pidText = (Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
      if ($pidText -match '^\d+$') {
        $procId = [int]$pidText
        Write-Host "Stopping $name PID $procId" -ForegroundColor Yellow
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Free-Port([int]$port) {
  $listeners = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
  foreach ($l in $listeners) {
    Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
  }
}

Stop-SBProcessesFromPidFiles
foreach ($p in $portsToFree) { Free-Port $p }

Write-Host 'Stopped SmartBuket API/processor processes and freed ports 8001-8003.'
if ($DownInfra) {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host 'docker is not available on PATH; infra was not stopped.'
    return
  }

  if (Test-Path -LiteralPath $compose) {
    Push-Location $root
    try {
      docker compose -f $compose down | Out-Null
      Write-Host 'Infra (docker compose) stopped.'
    } finally {
      Pop-Location
    }
  } else {
    Write-Host ('Compose file not found: ' + $compose)
  }
} else {
  Write-Host 'Infra (docker compose) is left running.'
}
