param(
  [Parameter(Mandatory=$true)][string]$ProjectId,
  [string]$Region = "us-central1",
  [string]$Repo = "sb-analytics",
  [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

function Exec([string]$Cmd) {
  Write-Host "> $Cmd"
  Invoke-Expression $Cmd
}

$AR = "$Region-docker.pkg.dev/$ProjectId/$Repo"

# Auth + make sure AR repo exists (Terraform can do this too)
Exec "gcloud auth configure-docker $Region-docker.pkg.dev"

# Build & push images
$images = @(
  @{ Name = "ingest-api"; Path = "services/ingest-api" },
  @{ Name = "query-api";  Path = "services/query-api"  },
  @{ Name = "reco-api";   Path = "services/reco-api"   },
  @{ Name = "processor";  Path = "services/processor"  },
  @{ Name = "outbox-publisher"; Path = "services/outbox-publisher" }
)

foreach ($img in $images) {
  $name = $img.Name
  $path = $img.Path
  $uri = "$AR/$name:$Tag"

  Exec "docker build -t $uri $path"
  Exec "docker push $uri"
}

Write-Host "Done. Now run Terraform with images set to:" -ForegroundColor Green
foreach ($img in $images) {
  $name = $img.Name
  Write-Host "  $name = $AR/$name:$Tag"
}
