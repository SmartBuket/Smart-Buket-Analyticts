param(
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$PythonPath,
  [Parameter(Mandatory=$false)][string]$RabbitMqUrl = '',
  [Parameter(Mandatory=$false)][string]$ProcessorGroupId = '',
  [Parameter(Mandatory=$true)][string]$PostgresDsn,
  [Parameter(Mandatory=$true)][string]$ArgLine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath $WorkDir

if ($RabbitMqUrl) {
  $env:SB_RABBITMQ_URL = $RabbitMqUrl
}

if ($ProcessorGroupId) {
  $env:SB_PROCESSOR_GROUP_ID = $ProcessorGroupId
}
$env:SB_POSTGRES_DSN = $PostgresDsn
$env:PYTHONUNBUFFERED = '1'

$pythonArgs = @()
if ($ArgLine) {
  $pythonArgs = $ArgLine -split '\|\|'
}

& $PythonPath @pythonArgs

