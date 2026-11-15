#Requires -Version 5.1
# uninstall.ps1 - reverses install.ps1 on Windows. Stops services, removes the helper task, the hosts
# block, generated configs/certs/CLI/app. Your sites.conf, settings and database data are KEPT unless
# you pass -Purge.
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Purge
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PSSource = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $PSSource 'lib\Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Modules.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Hosts.psm1') -DisableNameChecking -Force

Load-Config
Set-DryRun $DryRun.IsPresent
$paths = Get-DevStackPaths
$script:UninstallLog = Join-Path $env:TEMP 'devstack-uninstall.log'
function Write-ULog { param([string]$m) try { Add-Content -LiteralPath $script:UninstallLog -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) -ErrorAction SilentlyContinue } catch { } }
trap { Write-ULog ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace); exit 1 }
Write-ULog 'start'

Write-Host "dev-stack uninstaller (Windows)  (dry-run=$(Test-DryRun))"
if (-not ($Yes -or $DryRun)) {
    $ans = Read-Host 'Stop all dev-stack services and remove the stack? [y/N]'
    if ($ans -notmatch '^(y|yes)$') { Write-Host 'aborted'; return }
}

Write-Info 'closing the control app'
if (-not (Test-DryRun)) {
    Get-Process -Name DevStack -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
else { Write-Host '  [dry-run] close the Dev Stack app' -ForegroundColor DarkGray }

Write-Info 'stopping services'
foreach ($m in (Get-ModuleStopOrder)) {
    Stop-Module $m
}

Write-Info 'removing privileged helper task'
if (-not (Test-DryRun)) {
    if (Test-IsElevated) {
        try { Unregister-ScheduledTask -TaskName $paths.HelperTask -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        Write-Ok 'helper task removed'
    }
    else {
        Write-Warn "run this elevated to remove the '$($paths.HelperTask)' task:  powershell -File uninstall.ps1 -Yes"
    }
}

Write-Info 'removing managed hosts block'
if (-not (Test-DryRun)) {
    if (Test-IsElevated) {
        $hostsPath = Get-HostsPath
        $content = ''
        if (Test-Path -LiteralPath $hostsPath) {
            $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction SilentlyContinue
        }
        if ($null -eq $content) { $content = '' }
        if ($content -eq '') {
            Write-Note 'hosts file is empty; nothing to strip'
        }
        else {
            $pattern = '(?ms)^' + [regex]::Escape('# devstack-begin') + '.*?^' + [regex]::Escape('# devstack-end') + '\r?\n?'
            $stripped = [regex]::Replace($content, $pattern, '').TrimEnd()
            if ($stripped -eq $content.TrimEnd()) {
                Write-Note 'no dev-stack block in hosts'
            }
            else {
                # keep a safety copy before we touch the system file
                $bak = Join-Path $paths.BackupDir ('hosts-uninstall-' + (Get-Timestamp) + '.txt')
                New-Item -ItemType Directory -Force -Path $paths.BackupDir | Out-Null
                Set-Content -LiteralPath $bak -Value $content -Encoding ASCII -NoNewline -ErrorAction SilentlyContinue
                $out = $stripped
                if ($out -ne '') { $out = $out + "`r`n" }
                Set-Content -LiteralPath $hostsPath -Value $out -Encoding ASCII -NoNewline
                & ipconfig.exe /flushdns *> $null
                Write-Ok 'hosts block removed'
            }
        }
    }
    else { Write-Warn 'run elevated to strip the dev-stack block from the hosts file' }
}

Write-Info 'removing generated configs, certs and logs'
foreach ($d in @($paths.NginxConf, $paths.ApacheConf, $paths.CertsDir, $paths.LogsDir, $paths.RunDir, $paths.IpcDir, $paths.ConfDir)) {
    if (Test-DryRun) { Write-Host "  [dry-run] remove $d" -ForegroundColor DarkGray }
    else { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# The managed hosts block is the only thing we ever added, and it was stripped above. Restoring a
# backup taken while the block existed would re-introduce stale entries, so we do not restore it here
# (unrelated lines in the hosts file were never touched).

Write-Info 'keeping your configuration and data'
Write-Note "sites + settings : $($paths.ConfigDir)"
Write-Note "databases        : $($paths.Data)"
Write-Note "config backups   : $($paths.BackupDir)"

Write-Info 'removing CLI + installed package'
Write-ULog 'before cli removal'
if (-not (Test-DryRun)) {
    Remove-Item -LiteralPath (Get-CliShimPath) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paths.BinDir -Recurse -Force -ErrorAction SilentlyContinue
    # This script runs from inside pkg, and Windows locks the running file, so pkg cannot always be
    # deleted in-process. Hand removal to a detached cleanup process that runs after we exit.
    $pkgDir = $paths.PkgDir
    $cleanup = Join-Path $env:TEMP ('devstack-cleanup-' + (Get-Timestamp) + '.ps1')
    $body = "Start-Sleep -Seconds 2`r`n" +
        "Remove-Item -LiteralPath '$pkgDir' -Recurse -Force -ErrorAction SilentlyContinue`r`n" +
        "Remove-Item -LiteralPath '$cleanup' -Force -ErrorAction SilentlyContinue`r`n"
    Set-Content -LiteralPath $cleanup -Value $body -Encoding ASCII
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $cleanup + '"')) -WindowStyle Hidden
}
else {
    Write-Host "  [dry-run] remove $($paths.PkgDir) and $($paths.BinDir)" -ForegroundColor DarkGray
}

Write-ULog 'cli removal done'
Write-Info 'removing app, Start Menu shortcut and Apps & features entry'
$appDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\DevStack'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Dev Stack.lnk'
$regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevStack'
if (Test-DryRun) {
    Write-Host "  [dry-run] remove $appDir" -ForegroundColor DarkGray
    Write-Host "  [dry-run] remove $lnk" -ForegroundColor DarkGray
    Write-Host "  [dry-run] remove registry $regKey" -ForegroundColor DarkGray
}
else {
    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $regKey -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Purge) {
    Write-Info 'purge: removing configuration and database data'
    if (Test-DryRun) {
        Write-Host "  [dry-run] remove $($paths.ConfigDir)" -ForegroundColor DarkGray
        Write-Host "  [dry-run] remove $($paths.Data)" -ForegroundColor DarkGray
    }
    else {
        Remove-Item -LiteralPath $paths.ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $paths.Data -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Ok 'configuration and databases removed'
}
else {
    Write-Ok 'uninstall complete - your sites.conf, settings and databases were kept'
    Write-Note 'to delete those too, re-run with -Purge (this deletes database data)'
}
Write-Note 'Scoop packages were left in place; remove them manually if you wish'
Write-ULog 'done'
