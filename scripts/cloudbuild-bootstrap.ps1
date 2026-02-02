param(
  [Parameter(Mandatory=$true)][string]$ProjectId,
  [string]$Region = "us-central1",
  [string]$Repo = "sb-analytics",
  [Parameter(Mandatory=$true)][string]$TfStateBucket,
  [string]$RabbitmqSecretId = "sb-rabbitmq-url",
  [string]$CloudSqlInstance = "sb-analytics-pg",
  [string]$DbName = "sb_analytics",
  [bool]$AllowUnauthenticated = $true
)

$ErrorActionPreference = "Stop"

function Exec([string]$Cmd) {
  Write-Host "> $Cmd"
  Invoke-Expression $Cmd
}

Exec "gcloud config set project $ProjectId"

$allow = if ($AllowUnauthenticated) { "true" } else { "false" }

Exec "gcloud builds submit --config infra/gcp/cloudbuild/cloudbuild-bootstrap.yaml --substitutions _REGION=$Region,_REPO=$Repo,_TF_STATE_BUCKET=$TfStateBucket,_CLOUDSQL_INSTANCE=$CloudSqlInstance,_DB_NAME=$DbName,_RABBITMQ_SECRET_ID=$RabbitmqSecretId,_ALLOW_UNAUTH=$allow ."
