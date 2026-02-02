param(
  [string]$IngestBase = "http://localhost:8001",
  [string]$QueryBase  = "http://localhost:8002",
  [string]$RecoBase   = "http://localhost:8003",
  [int]$WaitSeconds   = 6
)

$ErrorActionPreference = "Stop"

Write-Host "Running demo flow (ingest -> processor -> query/offers)..." -ForegroundColor Cyan
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo-flow.ps1 -IngestBase $IngestBase -QueryBase $QueryBase -RecoBase $RecoBase -WaitSeconds $WaitSeconds

# Same demo IDs as demo-flow.ps1
$appUuid    = "b2a1d7d8-7f3f-4b35-8cbb-9a3a9b37d7b7"
$anonUserId = "u_demo_4f1c9b2d9a9c1f0d0a0b3c_demo"

Write-Host "Customer 360 (scoped by app_uuid)" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$QueryBase/v1/customers/$anonUserId?app_uuid=$appUuid" | ConvertTo-Json -Depth 20 | Write-Host

Write-Host "Done." -ForegroundColor Green
