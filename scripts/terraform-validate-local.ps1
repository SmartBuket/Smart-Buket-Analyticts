param(
  [string]$Dir = "infra/gcp/terraform"
)

$ErrorActionPreference = "Stop"

$tf = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform.exe"
if (!(Test-Path $tf)) {
  throw "terraform.exe not found at: $tf"
}

Push-Location $Dir

# For local dev/CI linting, avoid configuring remote backend (GCS) unless explicitly needed.
& $tf fmt -recursive
& $tf init -upgrade -backend=false -input=false
& $tf validate -no-color

Pop-Location
