param(
  [Parameter(Mandatory=$true)][string]$ProjectId,
  [string]$Region = "us-central1",
  [string]$Repo = "sb-analytics"
)

$ErrorActionPreference = "Stop"

function Exec([string]$Cmd) {
  Write-Host "> $Cmd"
  Invoke-Expression $Cmd
}

Exec "gcloud config set project $ProjectId"

# Submits the whole repo as build context
Exec "gcloud builds submit --config infra/gcp/cloudbuild/cloudbuild.yaml --substitutions _REGION=$Region,_REPO=$Repo ."

Write-Host "NOTE: For hardened security, run Cloud Build with the dedicated deploy service account (sb-cloudbuild-deploy) if your gcloud/trigger supports it." -ForegroundColor Yellow
