Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$logsDir = Join-Path $PSScriptRoot 'logs'

Get-ChildItem -LiteralPath $logsDir -Filter 'sb-*.pid' | ForEach-Object {
  $service = $_.BaseName
  $procId = [int](Get-Content -LiteralPath $_.FullName | Select-Object -First 1)
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  $cmd = $null
  if ($p) {
    $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    $cmd = $wmi.CommandLine
  }

  [PSCustomObject]@{
    Service = $service
    Pid = $procId
    Running = [bool]$p
    ProcessName = if ($p) { $p.ProcessName } else { $null }
    CommandLine = $cmd
  }
} | Format-Table -AutoSize
