#Requires -Version 5.1
# bin/DevStackWeb.ps1 - privileged helper body, run by the DevStackHelper scheduled task.
# Scope: ONLY the managed /etc/hosts-equivalent block. It never runs arbitrary commands and never
# evaluates user-controlled content. Reads request files, writes result files.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\lib\Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $here '..\lib\Sites.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $here '..\lib\Hosts.psm1') -DisableNameChecking -Force

$paths = Get-DevStackPaths
$reqDir = Join-Path $paths.IpcDir 'requests'
$resDir = Join-Path $paths.IpcDir 'results'
if (-not (Test-Path -LiteralPath $reqDir)) { return }

foreach ($f in (Get-ChildItem -LiteralPath $reqDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    try {
        $req = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ($req.PSObject.Properties.Name -contains 'id' -and $req.id) { $id = [string]$req.id }
        $message = ''
        switch ([string]$req.action) {
            'sync-hosts' { Sync-Hosts; $message = 'hosts synced' }
            default { throw "unknown action: $($req.action)" }
        }
        $res = [ordered]@{ id = $id; ok = $true; message = $message }
    }
    catch {
        $res = [ordered]@{ id = $id; ok = $false; message = "$($_.Exception.Message)" }
    }
    finally {
        Remove-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $resDir)) { New-Item -ItemType Directory -Force -Path $resDir | Out-Null }
    Set-Content -LiteralPath (Join-Path $resDir "$id.json") -Value ($res | ConvertTo-Json -Compress) -Encoding ASCII
}
