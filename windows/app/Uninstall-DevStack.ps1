#Requires -Version 5.1
# Uninstall-DevStack.ps1 - entry point used by the Windows "Apps & features" uninstall button.
# Relaunches the dev-stack uninstaller elevated (it must remove the helper task and the hosts block).
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pkg = Join-Path $env:LOCALAPPDATA 'devstack\pkg'
$uninstaller = Join-Path $pkg 'uninstall.ps1'
if (-not (Test-Path -LiteralPath $uninstaller)) {
    Write-Error "dev-stack is not installed (missing $uninstaller)."
    Start-Sleep -Seconds 3
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Yes
}
else {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $uninstaller + '"'), '-Yes'
    )
}
