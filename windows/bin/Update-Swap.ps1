#Requires -Version 5.1
# bin/Update-Swap.ps1 - detached package swapper.
# The running CLI holds files open inside the package directory, and Windows locks them, so the swap
# must happen in a separate process after the CLI exits. Retries the directory rename, restores the
# previous version on failure, prunes old backups, and optionally rebuilds the app.
param(
    [Parameter(Mandatory = $true)][string]$PkgDir,
    [Parameter(Mandatory = $true)][string]$NewDir,
    [Parameter(Mandatory = $true)][string]$BackupsDir,
    [string]$OldVersion = 'previous',
    [string]$NewVersion = 'new',
    [switch]$RebuildApp
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$log = Join-Path (Split-Path -Parent $BackupsDir) 'update-swap.log'
function Write-SwapLog {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -LiteralPath $log -Value "$ts $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-SwapLog "swap begin: $OldVersion -> $NewVersion"
if (-not (Test-Path -LiteralPath $NewDir)) {
    Write-SwapLog "ERROR: new package not found at $NewDir"
    exit 1
}
New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null
$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
$backup = Join-Path $BackupsDir "$OldVersion-$ts"

# Give the CLI a moment to exit and release its file handles.
Start-Sleep -Seconds 1

$movedOld = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        if (Test-Path -LiteralPath $PkgDir) {
            Move-Item -LiteralPath $PkgDir -Destination $backup -Force -ErrorAction Stop
            $movedOld = $true
        }
        break
    }
    catch {
        Start-Sleep -Milliseconds 300
    }
}

try {
    Move-Item -LiteralPath $NewDir -Destination $PkgDir -Force -ErrorAction Stop
    Write-SwapLog "swap success: $NewVersion installed"
}
catch {
    Write-SwapLog "ERROR: swap failed: $($_.Exception.Message)"
    if ($movedOld) {
        try { Move-Item -LiteralPath $backup -Destination $PkgDir -Force -ErrorAction Stop; Write-SwapLog 'previous version restored' }
        catch { Write-SwapLog "ERROR: could not restore previous version" }
    }
    exit 1
}

# Keep the three most recent backups.
try {
    Get-ChildItem -LiteralPath $BackupsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
catch { }

if ($RebuildApp) {
    $build = Join-Path $PkgDir 'app\build-app.ps1'
    if (Test-Path -LiteralPath $build) {
        Write-SwapLog 'rebuilding the app'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build *>> $log
            Write-SwapLog 'app rebuilt'
        }
        catch { Write-SwapLog "WARN: app rebuild failed: $($_.Exception.Message)" }
    }
    else { Write-SwapLog 'app build script not found; skipping rebuild' }
}

Write-SwapLog 'swap complete'
