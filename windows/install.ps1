#Requires -Version 5.1
# install.ps1 - dev-stack installer for Windows. Safe, idempotent, dry-run capable.
#
#   powershell -File windows\install.ps1 [-DryRun] [-Yes] [-NoScoop] [-Ssl] [-PhpMyAdmin]
#                                        [-HelperOnly] [-AppOnly] [-Uninstall]
#
# preflight -> backups -> Scoop packages -> base web configs -> vhosts -> install CLI + helper -> app
param(
    [switch]$DryRun,
    [switch]$Yes,
    [Alias('NoBrew')][switch]$NoScoop,
    [switch]$Ssl,
    [switch]$PhpMyAdmin,
    [switch]$HelperOnly,
    [switch]$AppOnly,
    [switch]$NoHelper,
    [switch]$Purge,
    [switch]$Uninstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PSSource = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $PSSource 'lib\Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Modules.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Sites.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Hosts.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\Ssl.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSSource 'lib\PhpMyAdmin.psm1') -DisableNameChecking -Force

Load-Config
Set-DryRun $DryRun.IsPresent
Set-BackupTimestamp (Get-Timestamp)

$paths = Get-DevStackPaths
$installPkg = $paths.PkgDir

if ($Uninstall) {
    $uninstallArgs = @()
    if ($DryRun) { $uninstallArgs += '-DryRun' }
    if ($Yes) { $uninstallArgs += '-Yes' }
    if ($Purge) { $uninstallArgs += '-Purge' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSSource 'uninstall.ps1') @uninstallArgs
    return
}

function Confirm-Action {
    param([string]$Prompt)
    if ($Yes -or $DryRun) { return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -match '^(y|yes)$')
}

function Invoke-Preflight {
    Write-Info 'preflight'
    if ($env:OS -ne 'Windows_NT') { Die 'dev-stack for Windows targets Windows 10/11 only' }
    Write-Note "$([Environment]::OSVersion.VersionString) - $env:PROCESSOR_ARCHITECTURE"
    if (-not (Test-DryRun)) { Ensure-Dirs }
    Write-Ok 'preflight passed'
}

function Invoke-Backups {
    Write-Info "backing up existing config to $($paths.BackupDir)\$(Get-Timestamp)"
    Backup-File (Get-HostsPath)
    Backup-File $paths.ConfigDir
    Write-Ok 'backups written'
}

function Invoke-Packages {
    if ($NoScoop) { Write-Info 'skipping packages (-NoScoop)'; return }
    $scoop = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoop) {
        Write-Warn 'Scoop not found - install it from https://scoop.sh, or use Chocolatey (see windows/docs/INSTALL.md)'
        return
    }
    Write-Info 'Scoop packages'
    # buckets that carry Apache/php version packages and extras
    foreach ($bucket in @('versions', 'extras')) {
        Invoke-Run -FilePath 'scoop' -ArgumentList @('bucket', 'add', $bucket)
    }
    $pkgs = @('nginx', 'apache', 'php', 'php83', 'php74', 'mysql', 'postgresql', 'redis', 'mailpit', 'mkcert', 'composer', 'wp-cli')
    foreach ($p in $pkgs) {
        Invoke-Run -FilePath 'scoop' -ArgumentList @('install', $p)
    }
    Write-Ok 'packages ready'
}

function Install-ApacheFallback {
    # Scoop's 'apache' package depends on a fossies.org mirror that intermittently returns 401.
    # If httpd is still missing, fetch Apache Lounge directly (plus mod_fcgid for PHP).
    if (Get-HttpdExe) { return }
    Write-Info 'Apache not present - fetching Apache Lounge directly'
    $scoop = Get-ScoopRoot
    $current = Join-Path $scoop 'apps\apache\current'
    $dl = Join-Path $env:TEMP ('devstack-apache-' + (Get-Timestamp))
    if (Test-DryRun) { Write-Host '  [dry-run] download Apache Lounge + mod_fcgid' -ForegroundColor DarkGray; return }
    try {
        New-Item -ItemType Directory -Force -Path $dl | Out-Null
        $page = Join-Path $dl 'page.html'
        & curl.exe -sL --max-time 60 -A 'Mozilla/5.0' -o $page 'https://www.apachelounge.com/download/'
        if ($LASTEXITCODE -ne 0) { Write-Warn 'could not reach apachelounge.com'; return }
        $html = Get-Content -LiteralPath $page -Raw
        $vsUsed = ''
        $zipHref = $null
        foreach ($vs in @('VS18', 'VS17')) {
            $m = [regex]::Match($html, 'href="([^"]*httpd-[0-9.]+-[0-9]+-Win64-' + $vs + '\.zip)"')
            if ($m.Success) { $zipHref = $m.Groups[1].Value; $vsUsed = $vs; break }
        }
        if (-not $zipHref) { Write-Warn 'no Apache Lounge Win64 build found'; return }
        $zip = Join-Path $dl 'httpd.zip'
        & curl.exe -sL --fail --max-time 300 -A 'Mozilla/5.0' -o $zip ('https://www.apachelounge.com' + $zipHref)
        if ($LASTEXITCODE -ne 0) { Write-Warn 'Apache download failed'; return }
        $ex = Join-Path $dl 'ex'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $root = Get-ChildItem $ex -Directory | Where-Object { $_.Name -like 'Apache*' } | Select-Object -First 1
        if (-not $root) { Write-Warn 'unexpected Apache archive layout'; return }
        if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $current | Out-Null
        Copy-Item -Path (Join-Path $root.FullName '*') -Destination $current -Recurse -Force

        $fm = [regex]::Match($html, 'href="([^"]*mod_fcgid-[0-9.]+-win64-' + $vsUsed + '\.zip)"')
        if ($fm.Success) {
            $fz = Join-Path $dl 'fcgid.zip'
            & curl.exe -sL --fail --max-time 120 -A 'Mozilla/5.0' -o $fz ('https://www.apachelounge.com' + $fm.Groups[1].Value)
            if ($LASTEXITCODE -eq 0) {
                $fe = Join-Path $dl 'fex'
                Expand-Archive -LiteralPath $fz -DestinationPath $fe -Force
                $so = Get-ChildItem $fe -Recurse -Filter 'mod_fcgid.so' | Select-Object -First 1
                if ($so) { Copy-Item -LiteralPath $so.FullName -Destination (Join-Path $current 'modules\mod_fcgid.so') -Force }
            }
        }
        Write-Ok 'Apache installed from Apache Lounge (with mod_fcgid)'
    }
    catch { Write-Warn ('Apache fallback failed: ' + $_.Exception.Message) }
    finally { Remove-Item -LiteralPath $dl -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-Cli {
    Write-Info 'installing CLI'
    if (Test-DryRun) {
        Write-Host "  [dry-run] copy package -> $installPkg ; write $(Join-Path $paths.BinDir 'devstack.cmd')" -ForegroundColor DarkGray
        return
    }
    if (Test-Path -LiteralPath $installPkg) { Remove-Item -LiteralPath $installPkg -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $installPkg | Out-Null
    Copy-Item -Path (Join-Path $PSSource '*') -Destination $installPkg -Recurse -Force
    New-Item -ItemType Directory -Force -Path $paths.BinDir | Out-Null
    $shim = Join-Path $paths.BinDir 'devstack.cmd'
    $content = "@echo off`r`nsetlocal`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installPkg\devstack.ps1`" %*`r`nexit /b %errorlevel%`r`n"
    Set-Content -LiteralPath $shim -Value $content -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if ($userPath -notlike "*$($paths.BinDir)*") {
        $newPath = $userPath.TrimEnd(';') + ';' + $paths.BinDir
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Note "added $($paths.BinDir) to your user PATH (open a new terminal)"
    }
    Write-Ok "CLI: $shim"
}

function Install-Helper {
    Write-Info 'privileged helper (scheduled task)'
    $script = Join-Path $installPkg 'bin\Install-HelperTask.ps1'
    if (Test-DryRun) { Write-Host "  [dry-run] register scheduled task DevStackHelper (one UAC prompt)" -ForegroundColor DarkGray; return }
    if (-not (Test-Path -LiteralPath $script)) { Write-Warn 'Install-HelperTask.ps1 missing from the package'; return }
    try {
        if (Test-IsElevated) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -PackageRoot $installPkg
        }
        else {
            Write-Note 'Windows will ask for elevation once'
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-PackageRoot', ('"' + $installPkg + '"')) -join ' '
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait
        }
        Write-Ok 'helper task installed'
    }
    catch {
        Write-Warn 'helper task not installed (elevation cancelled). Re-run: powershell -File "bin\Install-HelperTask.ps1" elevated.'
    }
}

function Install-AppRegistration {
    $appDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\DevStack'
    $exe = Join-Path $appDir 'DevStack.exe'
    if (Test-DryRun) { Write-Host '  [dry-run] register Dev Stack in the Start Menu and Apps & features' -ForegroundColor DarkGray; return }
    if (-not (Test-Path -LiteralPath $exe)) { Write-Warn 'app not built; skipping Start Menu / Apps registration'; return }

    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $programs | Out-Null
    $lnk = Join-Path $programs 'Dev Stack.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $exe
    $sc.WorkingDirectory = $appDir
    $sc.IconLocation = "$exe,0"
    $sc.Description = 'dev-stack control app'
    $sc.Save()

    $uninstaller = Join-Path $installPkg 'app\Uninstall-DevStack.ps1'
    $uninstallCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '"'
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DevStack'
    New-Item -Path $key -Force | Out-Null
    $size = 0
    try { $size = [int](((Get-ChildItem -LiteralPath $appDir -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1KB) } catch { }
    New-ItemProperty -Path $key -Name DisplayName -Value 'Dev Stack' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayVersion -Value (Get-DevStackVersion) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name Publisher -Value 'dev-stack' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayIcon -Value $exe -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name InstallLocation -Value $appDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name UninstallString -Value $uninstallCmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name QuietUninstallString -Value $uninstallCmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name InstallDate -Value ((Get-Date).ToString('yyyyMMdd')) -PropertyType String -Force | Out-Null
    Write-Ok 'registered Dev Stack in the Start Menu and Apps & features'
}

function Seed-Sites {
    if (Test-Path -LiteralPath $paths.SitesConf) { Write-Note 'sites.conf already present'; return }
    if (Test-DryRun) { Write-Host "  [dry-run] create $($paths.SitesConf)" -ForegroundColor DarkGray; return }
    New-Item -ItemType Directory -Force -Path $paths.ConfigDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSSource 'config\sites.conf.example') -Destination $paths.SitesConf -Force
    Write-Note "created $($paths.SitesConf)"
}

function Build-App {
    Write-Info 'building the app'
    $b = Join-Path $PSSource 'app\build-app.ps1'
    if (-not (Test-Path -LiteralPath $b)) { Write-Note 'app\build-app.ps1 not found; skipping'; return }
    Invoke-Run -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $b)
}

function Show-Summary {
    Write-Host ''
    Write-Ok "dev-stack $(Get-DevStackVersion) installed (Windows)"
    Write-Note "config:   $($paths.SitesConf)"
    Write-Note "backups:  $($paths.BackupDir)\$(Get-Timestamp)"
    Write-Note 'next:     open "Dev Stack" from the Start Menu, or run: devstack status'
    Write-Note 'uninstall: Settings > Apps > Installed apps > Dev Stack > Uninstall'
    Write-Note 'your sites.conf, settings and databases are kept on reinstall and uninstall'
    Write-Note 'disclaimer: provided as-is, no warranty - back up your databases and project files'
}

# ---------------------------------------------------------------- run
Write-Host "dev-stack installer (Windows) v$(Get-DevStackVersion)  (dry-run=$(Test-DryRun))"
Invoke-Preflight

if (-not $HelperOnly -and -not $AppOnly) {
    Invoke-Backups
    Invoke-Packages
    Install-ApacheFallback
    if (-not (Test-DryRun)) {
        Write-BaseConfigs
        Sync-Sites | Out-Null
    }
    Seed-Sites
    if ($Ssl) {
        Write-Info 'enabling HTTPS (mkcert)'
        Install-MkcertCa
        New-DevStackCert
        Set-Config 'SSL' '1'
        if (-not (Test-DryRun)) { Sync-Sites | Out-Null }
    }
    Install-Cli
}

if (-not $AppOnly -and -not $NoHelper) { Install-Helper }

if (-not $HelperOnly) {
    if (-not (Test-DryRun) -and -not $AppOnly) { Sync-Sites | Out-Null }
    Build-App
    Install-AppRegistration
}

if ($PhpMyAdmin -and -not $HelperOnly -and -not $AppOnly) {
    Install-Pma
}

Show-Summary
