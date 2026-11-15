#Requires -Version 5.1
# lib/PhpMyAdmin.psm1 - optional phpMyAdmin provisioning on Windows.
# Downloads phpMyAdmin, verifies the published SHA-256, installs under %USERPROFILE%\Sites\phpmyadmin,
# writes a cookie-auth config.inc.php (no password stored) and registers phpmyadmin.test on PHP 8.3.
Set-StrictMode -Version Latest

$script:PmaDir = $env:DEVSTACK_PMA_DIR
if (-not $script:PmaDir) { $script:PmaDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Sites\phpmyadmin' }
$script:PmaVersionUrl = 'https://www.phpmyadmin.net/home_page/version.json'
$script:PmaFilesBase = 'https://files.phpmyadmin.net/phpMyAdmin'
$script:PmaMarker = '.devstack-pma'
$script:PmaPhp = '8.3'
$script:PmaHost = 'phpmyadmin.test'

function Get-PmaMarkerPath { return (Join-Path $script:PmaDir $script:PmaMarker) }

function Test-PmaInstalled {
    return ((Test-Path -LiteralPath (Join-Path $script:PmaDir 'index.php')) -and
        (Test-Path -LiteralPath (Join-Path $script:PmaDir 'config.inc.php')))
}

function Test-PmaManaged { return (Test-Path -LiteralPath (Get-PmaMarkerPath)) }

function Get-PmaVersion {
    if (Test-Path -LiteralPath (Get-PmaMarkerPath)) { return ((Get-Content -LiteralPath (Get-PmaMarkerPath) -Raw).Trim()) }
    return ''
}

function Test-PmaRegistered {
    foreach ($s in @(Get-Sites)) { if ($s.Host -eq $script:PmaHost) { return $true } }
    return $false
}

function Get-PmaLatestVersion {
    try {
        $r = Invoke-WebRequest -Uri $script:PmaVersionUrl -UseBasicParsing -TimeoutSec 15
        $obj = $r.Content | ConvertFrom-Json
        return [string]$obj.version
    }
    catch { return '' }
}

function Show-PmaStatus {
    Write-Info 'phpMyAdmin'
    if (Test-PmaInstalled) {
        if (Test-PmaManaged) { Write-Ok "installed by dev-stack: v$(Get-PmaVersion) at $script:PmaDir" }
        else { Write-Warn "found at $script:PmaDir, but not installed by dev-stack (left untouched)" }
    }
    else {
        Write-Note 'not installed - add it with:  devstack phpmyadmin install'
    }
    if (Test-PmaRegistered) { Write-Ok "site $script:PmaHost is registered" }
    else { Write-Note "site $script:PmaHost is not registered yet" }
    if (Test-PmaInstalled) {
        $scheme = 'http'
        if (Test-SslEnabled) { $scheme = 'https' }
        Write-Note "url: ${scheme}://$script:PmaHost"
    }
}

function Get-PmaConfigContent {
    param([string]$Secret, [string]$TempDir)
    $mysqlPort = Get-ConfigValue 'MYSQL_PORT'
    return @"
<?php
// Written by dev-stack. Authentication is "cookie": log in with a MySQL account each time,
// so no database password is kept on disk.
`$cfg['blowfish_secret'] = '$Secret';

`$i = 0;
`$i++;
`$cfg['Servers'][`$i]['auth_type'] = 'cookie';
`$cfg['Servers'][`$i]['host'] = '127.0.0.1';
`$cfg['Servers'][`$i]['port'] = '$mysqlPort';
`$cfg['Servers'][`$i]['compress'] = false;
`$cfg['Servers'][`$i]['AllowNoPassword'] = false;
`$cfg['TempDir'] = '$TempDir';
"@
}

function Install-Pma {
    param([switch]$Force)
    $paths = Get-DevStackPaths
    Write-Info 'phpMyAdmin setup'
    if (Test-DryRun) {
        Write-Host ("  [dry-run] download the latest phpMyAdmin -> {0} ; write config.inc.php (cookie auth) ; register {1}" -f $script:PmaDir, $script:PmaHost) -ForegroundColor DarkGray
        return
    }
    if ((Test-PmaInstalled) -and -not (Test-PmaManaged) -and -not $Force) {
        Die "$script:PmaDir already holds a phpMyAdmin that dev-stack did not install.`n  Refusing to overwrite it - re-run with --force to back it up automatically."
    }

    $ver = Get-PmaLatestVersion
    if (-not $ver) { Die 'could not read the current phpMyAdmin version (no network?)' }
    Write-Note "latest: phpMyAdmin $ver"

    $ts = Get-Timestamp
    $tmp = Join-Path $paths.DataDir ".pma-tmp-$ts"
    $zipName = "phpMyAdmin-$ver-all-languages.zip"
    $url = "$script:PmaFilesBase/$ver/$zipName"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp $zipName

    Write-Info "downloading phpMyAdmin $ver"
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300 }
    catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; Die "download failed: $url" }

    try {
        $r = Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing -TimeoutSec 20
        $want = (($r.Content -split '\s+')[0]).Trim().ToLower()
    }
    catch { $want = '' }

    if ($want) {
        $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $have) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; Die "checksum mismatch (expected $want, got $have)" }
        Write-Ok 'SHA-256 verified'
    }
    else { Write-Warn 'checksum could not be fetched - continuing unverified' }

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory -Filter 'phpMyAdmin-*' | Select-Object -First 1
    if (-not $src -or -not (Test-Path -LiteralPath (Join-Path $src.FullName 'index.php'))) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Die 'unexpected archive layout'
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:PmaDir) | Out-Null
    if (Test-Path -LiteralPath $script:PmaDir) {
        $bak = "$script:PmaDir.devstack-backup-$ts"
        Write-Note "moving the previous install aside: $bak"
        Move-Item -LiteralPath $script:PmaDir -Destination $bak -Force
    }
    Move-Item -LiteralPath $src.FullName -Destination $script:PmaDir -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Info 'writing config.inc.php (cookie auth - nothing is stored)'
    $tempDir = Join-Path $paths.DataDir 'pma-tmp'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $bytes = New-Object 'byte[]' 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = [Convert]::ToBase64String($bytes)
    Set-Content -LiteralPath (Join-Path $script:PmaDir 'config.inc.php') -Value (Get-PmaConfigContent -Secret $secret -TempDir $tempDir) -Encoding UTF8
    Set-Content -LiteralPath (Get-PmaMarkerPath) -Value $ver -Encoding ASCII
    Write-Ok "phpMyAdmin $ver installed at $script:PmaDir"

    if (-not (Test-PmaRegistered)) {
        New-Item -ItemType Directory -Force -Path (Get-DevStackPaths).ConfigDir | Out-Null
        Add-Content -LiteralPath (Get-DevStackPaths).SitesConf -Value ("{0} | {1} | {2} | php" -f $script:PmaHost, $script:PmaDir, $script:PmaPhp) -Encoding ASCII
        Write-Ok "registered $script:PmaHost -> $script:PmaDir (php $script:PmaPhp)"
    }
    else { Write-Note "site $script:PmaHost already registered" }

    $result = Sync-Sites
    if ($result.ApacheChanged) { Restart-Apache }
    if ($result.NginxChanged) { Reload-Nginx }
    Invoke-HelperSyncHosts | Out-Null
    $scheme = 'http'
    if (Test-SslEnabled) { $scheme = 'https' }
    Write-Ok "phpMyAdmin ready: ${scheme}://$script:PmaHost (log in with a MySQL account)"
}
