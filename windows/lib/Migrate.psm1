#Requires -Version 5.1
# lib/Migrate.psm1 - discover sites from other local stacks (XAMPP, WAMP, Laragon, Herd/Valet).
# Read-only discovery: it never modifies the other tools. Import writes lines to sites.conf.
Set-StrictMode -Version Latest

function Get-MigrateEnvPath {
    param([string]$Name, [string]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v }
    return $Default
}

function Map-PhpVersion {
    param([string]$Version)
    if ($Version -and ($Version -match '(\d+)\.(\d+)')) {
        $maj = [int]$Matches[1]
        $min = [int]$Matches[2]
        if ($maj -ge 8 -and $min -ge 4) { return '8.5' }
        if ($maj -eq 8) { return '8.3' }
        if ($maj -eq 7) { return '7.4' }
    }
    return '8.5'
}

function Get-PhpVersionFromPath {
    param([string]$Path)
    if (-not $Path) { return '8.5' }
    if ($Path -match 'php[-_ ]?(\d+)\.(\d+)') { return (Map-PhpVersion ($Matches[1] + '.' + $Matches[2])) }
    if ($Path -match 'php(\d)(\d)') { return (Map-PhpVersion ($Matches[1] + '.' + $Matches[2])) }
    return '8.5'
}

function Get-PhpVersionFromExe {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $v = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
        if ($v -and ($v -match '(\d+)\.(\d+)')) { return (Map-PhpVersion $v) }
    }
    catch { }
    return $null
}

function Get-SiteKind {
    param([string]$DocRoot)
    if (-not $DocRoot) { return 'php' }
    if ((Split-Path -Leaf $DocRoot) -eq 'public') { return 'laravel' }
    if (Test-Path -LiteralPath (Join-Path $DocRoot 'wp-config.php')) { return 'wp' }
    if (Test-Path -LiteralPath (Join-Path $DocRoot 'artisan')) { return 'laravel' }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $DocRoot) 'artisan')) { return 'laravel' }
    return 'php'
}

function New-MigrateSite {
    param([string]$HostName, [string]$DocRoot, [string]$Php, [string]$Source, [string[]]$Aliases = @())
    if (-not $HostName -or -not $DocRoot) { return $null }
    $h = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
    if ($h -notmatch '^[a-z0-9][a-z0-9.-]*$') { return $null }
    $dr = $DocRoot.Trim().Trim('"') -replace '/', '\'
    $cleanAliases = @()
    foreach ($a in $Aliases) {
        $x = $a.Trim().TrimEnd('.').ToLowerInvariant()
        if ($x -and $x -ne $h -and ($x -match '^[a-z0-9][a-z0-9.-]*$') -and ($cleanAliases -notcontains $x)) {
            $cleanAliases += $x
        }
    }
    return [pscustomobject]@{
        Host    = $h
        DocRoot = $dr
        Php     = (Map-PhpVersion $Php)
        Kind    = (Get-SiteKind $dr)
        Aliases = ($cleanAliases -join ',')
        Source  = $Source
    }
}

function Import-VhostFile {
    param([string]$Path, [string]$Source, [string]$DefaultPhp = '8.5')
    $sites = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $sites }
    $inBlock = $false
    $serverName = ''
    $aliases = @()
    $docroot = ''

    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        if ($line -match '(?i)^<VirtualHost\b') {
            $inBlock = $true; $serverName = ''; $aliases = @(); $docroot = ''
            continue
        }
        if ($line -match '(?i)^</VirtualHost>') {
            if ($inBlock -and $docroot) {
                $names = @()
                if ($serverName) { $names += $serverName }
                $names += $aliases
                $clean = @()
                foreach ($n in $names) {
                    $x = $n.Trim().TrimEnd(';').Trim()
                    $x = ($x -replace ':\d+$', '').ToLowerInvariant()
                    if ($x -and ($clean -notcontains $x)) { $clean += $x }
                }
                if ($clean.Count -gt 0) {
                    $primary = $clean[0]
                    $al = @()
                    if ($clean.Count -gt 1) { $al = $clean[1..($clean.Count - 1)] }
                    $site = New-MigrateSite -HostName $primary -DocRoot $docroot -Php $DefaultPhp -Source $Source -Aliases $al
                    if ($site) { $sites += $site }
                }
            }
            $inBlock = $false
            continue
        }
        if (-not $inBlock) { continue }

        if ($line -match '(?i)^ServerName\s+(.+)$') {
            $serverName = $Matches[1].Trim().TrimEnd(';')
        }
        elseif ($line -match '(?i)^ServerAlias\s+(.+)$') {
            $aliases = @($Matches[1].Trim().TrimEnd(';') -split '\s+')
        }
        elseif ($line -match '(?i)^DocumentRoot\s+(.+)$') {
            $docroot = $Matches[1].Trim().TrimEnd(';').Trim('"')
        }
    }
    return $sites
}

function Get-XamppSites {
    $root = Get-MigrateEnvPath 'DEVSTACK_XAMPP_DIR' 'C:\xampp'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $php = Get-PhpVersionFromExe (Join-Path $root 'php\php.exe')
    if (-not $php) { $php = '8.5' }
    $sites = @()
    $vhost = Join-Path $root 'apache\conf\extra\httpd-vhosts.conf'
    $sites += Import-VhostFile -Path $vhost -Source 'xampp' -DefaultPhp $php
    # XAMPP's default web root: one site per top-level folder in htdocs
    $htdocs = Join-Path $root 'htdocs'
    if (Test-Path -LiteralPath $htdocs) {
        foreach ($d in (Get-ChildItem -LiteralPath $htdocs -Directory -ErrorAction SilentlyContinue)) {
            $doc = $d.FullName
            $pub = Join-Path $doc 'public'
            if (Test-Path -LiteralPath $pub) { $doc = $pub }
            $site = New-MigrateSite -HostName ($d.Name + '.test') -DocRoot $doc -Php $php -Source 'xampp'
            if ($site) { $sites += $site }
        }
    }
    return $sites
}

function Get-WampSites {
    $roots = @()
    $envRoot = [Environment]::GetEnvironmentVariable('DEVSTACK_WAMP_DIR')
    if ($envRoot) { $roots += $envRoot }
    $roots += @('C:\wamp64', 'C:\wamp')
    $sites = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $phpExe = Get-ChildItem -Path (Join-Path $root 'bin\php\php*\php.exe') -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        $php = if ($phpExe) { (Get-PhpVersionFromPath $phpExe.FullName) } else { '8.5' }
        $vhosts = Get-ChildItem -Path (Join-Path $root 'bin\apache\apache*\conf\extra\httpd-vhosts.conf') -ErrorAction SilentlyContinue
        foreach ($v in $vhosts) { $sites += Import-VhostFile -Path $v.FullName -Source 'wamp' -DefaultPhp $php }
    }
    return $sites
}

function Get-LaragonSites {
    $root = Get-MigrateEnvPath 'DEVSTACK_LARAGON_DIR' 'C:\laragon'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $phpExe = Get-ChildItem -Path (Join-Path $root 'bin\php\php*\php.exe') -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    $php = if ($phpExe) { (Get-PhpVersionFromPath $phpExe.FullName) } else { '8.5' }

    $sites = @()
    $siteConfDir = Join-Path $root 'etc\apache2\sites-enabled'
    if (Test-Path -LiteralPath $siteConfDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $siteConfDir -Filter '*.conf' -ErrorAction SilentlyContinue)) {
            $sites += Import-VhostFile -Path $f.FullName -Source 'laragon' -DefaultPhp $php
        }
    }
    $www = Join-Path $root 'www'
    if (Test-Path -LiteralPath $www) {
        foreach ($d in (Get-ChildItem -LiteralPath $www -Directory -ErrorAction SilentlyContinue)) {
            $doc = $d.FullName
            $pub = Join-Path $doc 'public'
            if (Test-Path -LiteralPath $pub) { $doc = $pub }
            $site = New-MigrateSite -HostName ($d.Name + '.test') -DocRoot $doc -Php $php -Source 'laragon'
            if ($site) { $sites += $site }
        }
    }
    return $sites
}

function Get-HerdSites {
    $dirs = @()
    $envDir = [Environment]::GetEnvironmentVariable('DEVSTACK_HERD_DIR')
    if ($envDir) { $dirs += $envDir }
    $dirs += @((Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\herd'),
        (Join-Path $env:APPDATA 'Herd'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\valet'))
    $sites = @()

    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }

        foreach ($jf in (Get-ChildItem -LiteralPath $d -Recurse -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $obj = $null
            try { $obj = Get-Content -LiteralPath $jf.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($null -eq $obj) { continue }

            if ($obj.PSObject.Properties.Name -contains 'sites') {
                $s = $obj.sites
                if ($s -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($p in $s.PSObject.Properties) {
                        $site = New-MigrateSite -HostName $p.Name -DocRoot ([string]$p.Value) -Php '8.5' -Source 'herd'
                        if ($site) { $sites += $site }
                    }
                }
                elseif ($s -is [System.Array]) {
                    foreach ($item in $s) {
                        $nm = [string]$item.name
                        $path = [string]$item.path
                        if (-not $nm -and $path) { $nm = (Split-Path -Leaf $path) + '.test' }
                        if ($nm -and $path) {
                            $site = New-MigrateSite -HostName $nm -DocRoot $path -Php '8.5' -Source 'herd'
                            if ($site) { $sites += $site }
                        }
                    }
                }
            }

            if ($obj.PSObject.Properties.Name -contains 'paths') {
                $tld = 'test'
                if (($obj.PSObject.Properties.Name -contains 'tld') -and $obj.tld) { $tld = [string]$obj.tld }
                foreach ($p in $obj.paths) {
                    if (-not (Test-Path -LiteralPath $p)) { continue }
                    foreach ($sd in (Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue)) {
                        $site = New-MigrateSite -HostName ($sd.Name + '.' + $tld) -DocRoot $sd.FullName -Php '8.5' -Source 'herd'
                        if ($site) { $sites += $site }
                    }
                }
            }
        }

        $sitesDir = Join-Path $d 'Sites'
        if (Test-Path -LiteralPath $sitesDir) {
            foreach ($item in (Get-ChildItem -LiteralPath $sitesDir -ErrorAction SilentlyContinue)) {
                $target = $item.FullName
                if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
                    if ($item.Target -is [System.Array]) { $target = [string]$item.Target[0] } else { $target = [string]$item.Target }
                }
                $site = New-MigrateSite -HostName ($item.Name + '.test') -DocRoot $target -Php '8.5' -Source 'herd'
                if ($site) { $sites += $site }
            }
        }
    }
    return $sites
}

function Get-MigrationSites {
    param([string]$Source = 'all')
    $all = @()
    if ($Source -eq 'all' -or $Source -eq 'xampp') { $all += Get-XamppSites }
    if ($Source -eq 'all' -or $Source -eq 'wamp') { $all += Get-WampSites }
    if ($Source -eq 'all' -or $Source -eq 'laragon') { $all += Get-LaragonSites }
    if ($Source -eq 'all' -or $Source -eq 'herd') { $all += Get-HerdSites }

    $seen = @{}
    $unique = @()
    foreach ($s in $all) {
        $key = $s.Host.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $s
        }
    }
    return $unique
}
