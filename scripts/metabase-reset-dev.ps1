param(
  [string]$MetabaseUrl = 'http://localhost:3001',
  [string]$AdminEmail = 'admin@smartbuket.com',
  # Metabase rejects very common passwords like "admin".
  [string]$AdminPassword = 'Dev!SmartBuket2026#',
  [switch]$NoBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Assert-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker is not available on PATH'
  }
  docker info | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Docker engine is not reachable. Start Docker Desktop and retry.'
  }
}

function Wait-ForMetabase([int]$timeoutSeconds = 180) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-RestMethod -Method Get -Uri ($MetabaseUrl.TrimEnd('/') + '/api/health') -TimeoutSec 3
      if ($h.status -eq 'ok') { return }
    } catch {}
    Start-Sleep -Seconds 2
  }
  throw "Metabase did not become healthy within ${timeoutSeconds}s: $MetabaseUrl"
}

Assert-Docker

Write-Host 'Stopping Metabase...' -ForegroundColor Cyan
try { docker stop sb-metabase | Out-Null } catch {}

Write-Host 'Resetting Metabase application DB (sb_metabase)...' -ForegroundColor Cyan
# Metabase uses Postgres as application DB (see infra/docker-compose.yml). We reset that DB for a clean dev setup.
# Postgres 16 supports DROP DATABASE ... WITH (FORCE) to disconnect active sessions.
docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS sb_metabase WITH (FORCE);" | Out-Null
# Drop role after DB is gone (ignore if it doesn't exist)
docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS sb_metabase;" | Out-Null

Write-Host 'Recreating Metabase role+db...' -ForegroundColor Cyan
docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE sb_metabase LOGIN PASSWORD 'sb_metabase';" | Out-Null
docker exec -i sb-postgres psql -U sb -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE sb_metabase OWNER sb_metabase;" | Out-Null

Write-Host 'Starting Metabase...' -ForegroundColor Cyan
Push-Location $root
try {
  docker compose -f (Join-Path $root 'infra\docker-compose.yml') up -d --force-recreate metabase | Out-Null
} finally {
  Pop-Location
}

Wait-ForMetabase
Write-Host 'Metabase is healthy.' -ForegroundColor Green

if (-not $NoBootstrap) {
  Write-Host 'Bootstrapping Metabase (site branding + DB connection)...' -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot 'metabase-bootstrap.ps1') -MetabaseUrl $MetabaseUrl -AdminEmail $AdminEmail -AdminPassword $AdminPassword -Force
}

Write-Host ''
Write-Host 'Metabase UI:' -ForegroundColor Green
Write-Host ("  {0}" -f $MetabaseUrl)
Write-Host 'Login:' -ForegroundColor Green
Write-Host ("  Email: {0}" -f $AdminEmail)
Write-Host ("  Password: {0}" -f $AdminPassword)
