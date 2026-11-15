#Requires -Version 5.1
# bin/Install-HelperTask.ps1 - register the DevStackHelper scheduled task.
# Must run ELEVATED (one UAC prompt). After registration, the unelevated CLI can trigger it with
# `schtasks /run` because it runs as the current user with highest privileges, only when logged on.
param(
    [string]$PackageRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Install-HelperTask.ps1 must run elevated (as Administrator).'
    exit 1
}

if (-not $PackageRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $PackageRoot = Split-Path -Parent $scriptDir
}
$helper = Join-Path $PackageRoot 'bin\DevStackWeb.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Error "missing helper at $helper"
    exit 1
}

$taskName = 'DevStackHelper'
$currentUser = $identity.Name
$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $helper + '"'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(5))
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'dev-stack privileged helper (hosts sync only)' -Force | Out-Null
Write-Host "registered scheduled task '$taskName' for $currentUser (highest privileges)"
