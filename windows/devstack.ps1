#Requires -Version 5.1
# devstack.ps1 - user-facing control CLI for the Windows dev stack.
# Mirrors bin/devstack on macOS: status|list|start|stop|restart|sites|add-site|sync|composer|ssl|
# phpmyadmin|update|doctor|version
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path $scriptDir 'lib'
Import-Module (Join-Path $libDir 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Modules.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Sites.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Hosts.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Ssl.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Update.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'PhpMyAdmin.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $libDir 'Migrate.psm1') -DisableNameChecking -Force

Load-Config

# ---------------------------------------------------------------- helpers
function Get-PhpExe {
    param([string]$Version)
    $cgi = Get-PhpCgiExe $Version
    if (-not $cgi) { return $null }
    $php = Join-Path (Split-Path -Parent $cgi) 'php.exe'
    if (Test-Path -LiteralPath $php) { return $php }
    return $cgi
}

function Show-Status {
    foreach ($r in @(Get-StatusRows)) {
        Write-Host ("{0}`t{1}`t{2}" -f $r.Name, $r.State, $r.Detail)
    }
}

function Invoke-Start {
    param([string]$Target)
    if ($Target -and -not (Test-ValidModule $Target)) { Die "unknown module: $Target" }
    $what = 'all'; if ($Target) { $what = $Target }
    Add-Log "start $what"
    if ($Target) { Start-Module $Target }
    else { foreach ($m in (Get-ModuleStartOrder)) { Start-Module $m } }
}

function Invoke-Stop {
    param([string]$Target)
    if ($Target -and -not (Test-ValidModule $Target)) { Die "unknown module: $Target" }
    $what = 'all'; if ($Target) { $what = $Target }
    Add-Log "stop $what"
    if ($Target) { Stop-Module $Target }
    else { foreach ($m in (Get-ModuleStopOrder)) { Stop-Module $m } }
}

function Invoke-Restart {
    param([string]$Target)
    if ($Target -and -not (Test-ValidModule $Target)) { Die "unknown module: $Target" }
    $what = 'all'; if ($Target) { $what = $Target }
    Add-Log "restart $what"
    if ($Target) { Restart-Module $Target }
    else { foreach ($m in (Get-ModuleStopOrder)) { Stop-Module $m }; foreach ($m in (Get-ModuleStartOrder)) { Start-Module $m } }
}

function Show-Sites {
    $paths = Get-DevStackPaths
    if (-not (Test-Path -LiteralPath $paths.SitesConf)) { Write-Warn "no sites config at $($paths.SitesConf)"; return }
    Write-Host ("{0,-22} {1,-6} {2,-45} {3}" -f 'HOST', 'PHP', 'DOCROOT', 'KIND')
    foreach ($s in @(Get-Sites)) {
        Write-Host ("{0,-22} {1,-6} {2,-45} {3}" -f $s.Host, $s.Php, $s.DocRoot, $s.Kind)
    }
}

function Add-Site {
    $hostName = Read-Host 'host (e.g. mysite.test)'
    $docroot = Read-Host 'docroot (e.g. C:\Sites\mysite)'
    $php = Read-Host 'php version [8.5]'
    if (-not $php) { $php = '8.5' }
    $kind = Read-Host 'kind [php]'
    if (-not $kind) { $kind = 'php' }
    if (-not $hostName -or -not $docroot) { Write-Warn 'host and docroot are required'; return }
    $paths = Get-DevStackPaths
    New-Item -ItemType Directory -Force -Path $paths.ConfigDir | Out-Null
    Add-Content -LiteralPath $paths.SitesConf -Value ("{0} | {1} | {2} | {3}" -f $hostName, $docroot, $php, $kind) -Encoding ASCII
    Write-Ok "added $hostName"
    Invoke-Sync
    Write-Note 'restart the web module to apply: devstack restart web'
}

function Invoke-Sync {
    Write-Info 'regenerating vhosts from sites.conf'
    Write-BaseConfigs
    $result = Sync-Sites
    if ($result.ApacheChanged) { Restart-Apache } else { Write-Note 'apache config unchanged' }
    if ($result.NginxChanged) { Reload-Nginx } else { Write-Note 'nginx config unchanged' }
    Invoke-HelperSyncHosts | Out-Null
    Write-Ok 'synced'
}

function Invoke-Composer {
    param([string[]]$Arguments = @())
    $site = ''
    $php = ''
    $want = @()
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        switch -Wildcard ($a) {
            '--site' { if ($i + 1 -lt $Arguments.Count) { $site = $Arguments[$i + 1] }; $i += 2; continue }
            '--site=*' { $site = $a.Substring(7); $i++; continue }
            '--php' { if ($i + 1 -lt $Arguments.Count) { $php = $Arguments[$i + 1] }; $i += 2; continue }
            '--php=*' { $php = $a.Substring(6); $i++; continue }
            '--' {
                $i++
                while ($i -lt $Arguments.Count) { $want += $Arguments[$i]; $i++ }
                continue
            }
            default { $want += $a; $i++ }
        }
    }

    $docroot = ''
    if ($site) {
        $found = @(Get-Sites) | Where-Object { $_.Host -eq $site } | Select-Object -First 1
        if (-not $found) { Die "unknown site: $site  (see: devstack sites)" }
        $docroot = $found.DocRoot
        if (-not $php) { $php = $found.Php }
    }
    if (-not $docroot -and -not $php) {
        foreach ($s in @(Get-Sites)) {
            $pr = Get-ProjectRoot $s.DocRoot
            if ($pr -and $PWD.Path.StartsWith($pr, [StringComparison]::OrdinalIgnoreCase)) {
                $docroot = $s.DocRoot
                $php = $s.Php
                break
            }
        }
    }
    if (-not $php) { $php = '8.5' }
    $phpExe = Get-PhpExe $php
    if (-not $phpExe) { Die "PHP $php not installed" }
    $composer = Get-ToolPath -Name 'composer' -EnvVar 'DEVSTACK_COMPOSER' -Fallbacks @((Join-Path (Get-ScoopRoot) 'shims\composer.bat'))
    if (-not $composer) { Die 'composer not found - run windows\install.ps1' }

    $workdir = $PWD.Path
    if ($docroot) {
        $root = Get-ProjectRoot $docroot
        $workdir = $root
        foreach ($c in @($docroot, $root)) {
            if ($c -and (Test-Path -LiteralPath (Join-Path $c 'composer.json'))) { $workdir = $c; break }
        }
    }
    Write-Info "composer - PHP $php - $workdir"
    Set-Location -LiteralPath $workdir
    $phpDir = Split-Path -Parent $phpExe
    $oldPath = $env:PATH
    $env:PATH = $phpDir + ';' + $oldPath
    try { & $composer @want }
    finally { $env:PATH = $oldPath }
}

function Invoke-Ssl {
    param([string[]]$Arguments = @())
    $sub = 'status'
    if ($Arguments.Count -gt 0) { $sub = [string]$Arguments[0] }
    $paths = Get-DevStackPaths
    switch ($sub) {
        'status' {
            Write-Info "SSL: $(Get-SslSummary)"
            if (Test-Path -LiteralPath $paths.Cert) {
                Write-Note "cert:    $($paths.Cert)"
                try {
                    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($paths.Cert)
                    Write-Note "expires: $($cert.NotAfter)"
                    Write-Note "subject: $($cert.Subject)"
                }
                catch { }
            }
            else { Write-Note 'no certificate issued yet' }
            if (Test-MkcertCa) { Write-Ok 'mkcert CA present' } else { Write-Warn 'mkcert CA not installed (run: devstack ssl enable)' }
            if ((Get-ListeningPorts).Contains([int](Get-ConfigValue 'SSL_PORT'))) { Write-Ok "listening on :$((Get-ConfigValue 'SSL_PORT'))" }
            else { Write-Note "nothing listening on :$((Get-ConfigValue 'SSL_PORT'))" }
        }
        'enable' {
            Install-MkcertCa
            New-DevStackCert
            Set-Config 'SSL' '1'
            $result = Sync-Sites
            if ($result.ApacheChanged) { Restart-Apache }
            Reload-Nginx
            Set-AppUrls 'https'
            Write-Ok "HTTPS enabled - sites now redirect :$((Get-ConfigValue 'NGINX_PORT')) -> :$((Get-ConfigValue 'SSL_PORT'))"
        }
        'disable' {
            Set-Config 'SSL' '0'
            $result = Sync-Sites
            if ($result.ApacheChanged) { Restart-Apache }
            Reload-Nginx
            Set-AppUrls 'http'
            Write-Ok 'HTTPS disabled - sites served over http only'
        }
        'renew' {
            New-DevStackCert
            Reload-Nginx
            Write-Ok 'certificate renewed'
        }
        default { Die 'usage: devstack ssl {enable|disable|status|renew}' }
    }
}

function Invoke-PhpMyAdmin {
    param([string[]]$Arguments = @())
    $sub = 'status'
    if ($Arguments.Count -gt 0) { $sub = [string]$Arguments[0] }
    switch ($sub) {
        'status' { Show-PmaStatus }
        'install' {
            if ($Arguments -contains '--force') { Install-Pma -Force } else { Install-Pma }
        }
        default { Die 'usage: devstack phpmyadmin [status|install [--force]]' }
    }
}

function Invoke-Update {
    param([string[]]$Arguments = @())
    $check = $false
    $json = $false
    $refresh = $false
    foreach ($a in $Arguments) {
        switch ($a) {
            '--check' { $check = $true }
            '--json' { $json = $true }
            '--refresh' { $refresh = $true }
            '--rollback' { Invoke-UpdateRollback; return }
            '--yes' { }
            '-y' { }
            '--no-helper' { }
            default { Die "unknown option: $a" }
        }
    }
    if ($check) {
        $mode = 'human'
        if ($json) { $mode = 'json' }
        Invoke-UpdateCheck -Mode $mode -Refresh:$refresh
    }
    else { Invoke-UpdateApply -AssumeYes }
}

function Invoke-Doctor {
    $fail = 0
    Write-Info 'dev-stack doctor'
    Write-Note "user: $env:USERNAME   ports: nginx $((Get-ConfigValue 'NGINX_PORT')) / apache $((Get-ConfigValue 'APACHE_PORT'))"

    Write-Info 'binaries'
    $checks = @(
        @{ N = 'nginx'; P = (Get-NginxExe) },
        @{ N = 'httpd'; P = (Get-HttpdExe) },
        @{ N = 'mysqld'; P = (Get-MySqlExe) },
        @{ N = 'postgres'; P = (Get-PostgresExe) },
        @{ N = 'redis-server'; P = (Get-RedisExe) },
        @{ N = 'mailpit'; P = (Get-MailpitExe) },
        @{ N = 'php-cgi 8.5'; P = (Get-PhpCgiExe '8.5') },
        @{ N = 'php-cgi 8.3'; P = (Get-PhpCgiExe '8.3') },
        @{ N = 'php-cgi 7.4'; P = (Get-PhpCgiExe '7.4') },
        @{ N = 'mkcert'; P = (Get-MkcertExe) }
    )
    foreach ($c in $checks) { if ($c.P) { Write-Ok $c.N } else { Write-Warn "$($c.N) missing"; $fail = 1 } }

    Write-Info 'services'
    foreach ($r in @(Get-StatusRows)) {
        if ($r.State -eq 'running') { Write-Ok "$($r.Name) (running)" }
        else { Write-Warn "$($r.Name) ($($r.State))"; $fail = 1 }
    }

    Write-Info 'config syntax'
    $paths = Get-DevStackPaths
    $nginx = Get-NginxExe
    $nginxConf = Get-NginxConfPath
    if ($nginx -and (Test-Path -LiteralPath $nginxConf)) {
        & $nginx -p $paths.NginxConf -c $nginxConf -t *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'nginx config valid' } else { Write-Warn 'nginx config problem'; $fail = 1 }
    }
    else { Write-Warn 'nginx config missing'; $fail = 1 }
    $httpd = Get-HttpdExe
    $apacheConf = Get-ApacheConfPath
    if ($httpd -and (Test-Path -LiteralPath $apacheConf)) {
        & $httpd -f $apacheConf -t *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'apache config valid' } else { Write-Warn 'apache config problem'; $fail = 1 }
    }
    else { Write-Warn 'apache config missing'; $fail = 1 }

    Write-Info 'privileged helper'
    if (Test-HelperTask) { Write-Ok "task '$($paths.HelperTask)' installed" }
    else { Write-Warn 'helper task not installed'; $fail = 1 }

    Write-Info 'update'
    $st = Get-UpdateStatus -Json (Get-UpdateJson)
    if ($st.Available) { Write-Ok "a newer release is available (devstack update)" }
    else { Write-Ok "up to date ($($st.Current))" }

    Write-Info 'ssl'
    if (Test-SslEnabled) {
        if (Test-Path -LiteralPath $paths.Cert) { Write-Ok 'certificate present' } else { Write-Warn 'SSL on but no certificate'; $fail = 1 }
        if (Test-MkcertCa) { Write-Ok 'mkcert CA present' } else { Write-Warn 'mkcert CA missing'; $fail = 1 }
        if ((Get-ListeningPorts).Contains([int](Get-ConfigValue 'SSL_PORT'))) { Write-Ok "listening :$((Get-ConfigValue 'SSL_PORT'))" }
        else { Write-Warn "nothing on :$((Get-ConfigValue 'SSL_PORT'))"; $fail = 1 }
    }
    else { Write-Note 'disabled (enable with: devstack ssl enable)' }

    Write-Info 'sites'
    $sites = @(Get-Sites)
    if ($sites.Count -eq 0) { Write-Warn 'no sites configured'; $fail = 1 }
    else {
        $scheme = 'http'
        if (Test-SslEnabled) { $scheme = 'https' }
        foreach ($s in $sites) {
            try {
                $resp = Invoke-WebRequest -Uri "${scheme}://$($s.Host)/" -UseBasicParsing -TimeoutSec 8
                $code = [int]$resp.StatusCode
                if ($code -ge 200 -and $code -lt 400) { Write-Ok "$($s.Host) $code" }
                else { Write-Warn "$($s.Host) $code"; $fail = 1 }
            }
            catch { Write-Warn "$($s.Host) no-response"; $fail = 1 }
        }
    }

    Write-Host ''
    if ($fail -eq 0) { Write-Ok 'all checks passed' } else { Write-Warn 'some checks failed (see above)' }
    return $fail
}

function Get-DefaultPhpVersion {
    $v = [string](Get-ConfigValue 'PHP_DEFAULT')
    if (-not $v) { $v = '8.5' }
    return $v
}

function Set-DefaultPhp {
    param([string]$Version)
    if (-not $Version) { Die 'usage: devstack php default <8.5|8.3|7.4>' }
    $exe = Get-PhpExe $Version
    if (-not $exe) { Die "PHP $Version is not installed (scoop install php83 / php74)" }
    Set-Config 'PHP_DEFAULT' $Version
    if (-not (Test-DryRun)) {
        $bin = (Get-DevStackPaths).BinDir
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $phpCmd = '@echo off' + "`r`n" + '"' + $exe + '" %*' + "`r`n"
        Set-Content -LiteralPath (Join-Path $bin 'php.cmd') -Value $phpCmd -Encoding ASCII
        $cgi = Get-PhpCgiExe $Version
        if ($cgi) {
            $cgiCmd = '@echo off' + "`r`n" + '"' + $cgi + '" %*' + "`r`n"
            Set-Content -LiteralPath (Join-Path $bin 'php-cgi.cmd') -Value $cgiCmd -Encoding ASCII
        }
        # Put the dev-stack bin directory first on the user PATH so our php.cmd takes precedence
        # over Scoop's php.exe shim (a .cmd in an earlier directory wins over a .exe later on PATH).
        $binNorm = $bin.TrimEnd('\')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $userPath) { $userPath = '' }
        $parts = @()
        foreach ($p in ($userPath -split ';')) {
            $t = $p.Trim()
            if ($t -and ($t.TrimEnd('\') -ne $binNorm)) { $parts += $t }
        }
        [Environment]::SetEnvironmentVariable('Path', ($bin + ';' + ($parts -join ';')), 'User')
        $env:PATH = $bin + ';' + $env:PATH
    }
    Write-Ok "default PHP is now $Version  ($exe)"
    Write-Note 'open a new terminal for the change to apply everywhere'
}

function Invoke-Php {
    param([string[]]$Arguments = @())
    $sub = 'status'
    if ($Arguments.Count -gt 0) { $sub = [string]$Arguments[0] }
    switch ($sub) {
        'status' {
            $def = Get-DefaultPhpVersion
            Write-Info "default PHP: $def"
            foreach ($v in @('8.5', '8.3', '7.4')) {
                $exe = Get-PhpExe $v
                if ($exe) {
                    $mark = ''
                    if ($v -eq $def) { $mark = '   (default)' }
                    Write-Note ("{0}   {1}{2}" -f $v, $exe, $mark)
                }
                else { Write-Warn "$v not installed" }
            }
            $cmd = Get-Command php -ErrorAction SilentlyContinue
            if ($cmd) { Write-Note ("php on PATH -> " + $cmd.Source) } else { Write-Note 'php is not on PATH' }
            Write-Note 'per-site PHP is set in sites.conf (php column) - apply with: devstack sync'
        }
        'list' {
            foreach ($v in @('8.5', '8.3', '7.4')) {
                $exe = Get-PhpExe $v
                if ($exe) { Write-Host ("{0}`t{1}" -f $v, $exe) }
            }
        }
        'default' { Set-DefaultPhp ([string]($Arguments | Select-Object -Skip 1 -First 1)) }
        default { Die 'usage: devstack php [status|list|default <version>]' }
    }
}

function Invoke-MigrateDb {
    param([string[]]$Arguments = @())
    if ($Arguments.Count -eq 0) { Die 'usage: devstack migrate db <dumpfile> [--engine mysql|pgsql] [--database NAME]' }
    $file = [string]$Arguments[0]
    $engine = 'mysql'
    $db = ''
    $i = 1
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        switch -Wildcard ($a) {
            '--engine' { if ($i + 1 -lt $Arguments.Count) { $engine = $Arguments[$i + 1] }; $i += 2; continue }
            '--engine=*' { $engine = $a.Substring(9); $i++; continue }
            '--database' { if ($i + 1 -lt $Arguments.Count) { $db = $Arguments[$i + 1] }; $i += 2; continue }
            '--database=*' { $db = $a.Substring(11); $i++; continue }
            default { Die "unknown option: $a" }
        }
    }
    if (-not (Test-Path -LiteralPath $file)) { Die "dump file not found: $file" }
    $engine = $engine.ToLowerInvariant()
    if ($engine -eq 'mysql') {
        if ((Get-ModuleState 'mysql') -ne 'running') { Start-Module 'mysql' }
        $mysql = Get-ToolPath -Name 'mysql' -EnvVar 'DEVSTACK_MYSQL_CLIENT' -Fallbacks @((Join-Path (Get-ScoopRoot) 'shims\mysql.exe'))
        if (-not $mysql) { Die 'mysql client not found' }
        if ($db) {
            if ($db -notmatch '^[A-Za-z0-9_]+$') { Die "invalid database name: $db" }
            $createSql = 'CREATE DATABASE IF NOT EXISTS `' + $db + '`;'
            & $mysql -u root -e $createSql
            if ($LASTEXITCODE -ne 0) { Die 'could not create the target database' }
        }
        $target = ''
        if ($db) { $target = '"' + $db + '"' }
        $cmd = '"' + $mysql + '" -u root ' + $target + ' < "' + $file + '"'
        & cmd.exe /c $cmd
        if ($LASTEXITCODE -ne 0) { Die "MySQL import failed (exit $LASTEXITCODE)" }
        Write-Ok "imported $file into MySQL"
    }
    elseif ($engine -eq 'pgsql' -or $engine -eq 'postgres') {
        if ((Get-ModuleState 'postgres') -ne 'running') { Start-Module 'postgres' }
        $psql = Get-ToolPath -Name 'psql' -EnvVar 'DEVSTACK_PSQL' -Fallbacks @((Join-Path (Get-ScoopRoot) 'apps\postgresql\current\bin\psql.exe'))
        if (-not $psql) { Die 'psql not found' }
        $pa = @('-U', $env:USERNAME, '-v', 'ON_ERROR_STOP=1')
        if ($db) { $pa += @('-d', $db) } else { $pa += @('-d', 'postgres') }
        $pa += @('-f', $file)
        & $psql @pa
        if ($LASTEXITCODE -ne 0) { Die "PostgreSQL import failed (exit $LASTEXITCODE)" }
        Write-Ok "imported $file into PostgreSQL"
    }
    else { Die 'engine must be mysql or pgsql' }
}

function Invoke-Migrate {
    param([string[]]$Arguments = @())
    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'db') {
        Invoke-MigrateDb -Arguments ($Arguments | Select-Object -Skip 1)
        return
    }
    $apply = $false
    $sync = $false
    $source = 'all'
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        switch -Wildcard ($a) {
            '--apply' { $apply = $true; $i++; continue }
            '--sync' { $sync = $true; $i++; continue }
            '--source' { if ($i + 1 -lt $Arguments.Count) { $source = $Arguments[$i + 1] }; $i += 2; continue }
            '--source=*' { $source = $a.Substring(9); $i++; continue }
            default { Die 'usage: devstack migrate [--source all|xampp|wamp|laragon|herd] [--apply [--sync]]  |  devstack migrate db <file> [--engine mysql|pgsql] [--database NAME]' }
        }
    }
    $source = $source.ToLowerInvariant()
    if (@('all', 'xampp', 'wamp', 'laragon', 'herd') -notcontains $source) { Die "unknown source: $source" }

    $sites = @(Get-MigrationSites -Source $source)
    if ($sites.Count -eq 0) {
        Write-Warn 'no sites found in XAMPP / WAMP / Laragon / Herd installs'
        Write-Note 'nothing changed. Add sites manually with: devstack add-site'
        return
    }

    $existing = @{}
    foreach ($s in @(Get-Sites)) { $existing[$s.Host.ToLowerInvariant()] = $true }

    Write-Info "detected $($sites.Count) site(s) from '$source':"
    Write-Host ("{0,-9} {1,-24} {2,-6} {3,-8} {4}" -f 'SOURCE', 'HOST', 'PHP', 'KIND', 'DOCROOT')
    $new = @()
    foreach ($s in $sites) {
        $key = $s.Host.ToLowerInvariant()
        $isNew = -not $existing.ContainsKey($key)
        $suffix = ''
        if (-not $isNew) { $suffix = '   (already configured)' }
        Write-Host ("{0,-9} {1,-24} {2,-6} {3,-8} {4}{5}" -f $s.Source, $s.Host, $s.Php, $s.Kind, $s.DocRoot, $suffix)
        if ($isNew) { $new += $s; $existing[$key] = $true }
    }

    if (-not $apply) {
        Write-Note 'dry run - nothing changed. Re-run with --apply to add these to sites.conf.'
        return
    }
    if ($new.Count -eq 0) { Write-Ok 'nothing new to add'; return }

    $conf = (Get-DevStackPaths).SitesConf
    New-Item -ItemType Directory -Force -Path (Get-DevStackPaths).ConfigDir | Out-Null
    if (-not (Test-Path -LiteralPath $conf)) { New-Item -ItemType File -Path $conf | Out-Null }
    foreach ($s in $new) {
        $line = ("{0} | {1} | {2} | {3}" -f $s.Host, $s.DocRoot, $s.Php, $s.Kind)
        if ($s.Aliases) { $line = $line + ' | ' + $s.Aliases }
        Add-Content -LiteralPath $conf -Value $line -Encoding ASCII
    }
    Write-Ok "added $($new.Count) site(s) to $conf"
    if ($sync) { Invoke-Sync } else { Write-Note 'apply with: devstack sync' }
}

function Show-Usage {
    Write-Host @"
devstack $(Get-DevStackVersion) - Windows local dev stack control

Usage: devstack <command> [module]

Commands:
  status                 show every module and its state
  start [module]         start all modules (or one)
  stop  [module]         stop all modules (or one)
  restart [module]       restart all modules (or one)
  list                   list module ids
  sites                  list configured sites
  add-site               interactively add a site
  sync                   regenerate vhosts + sync hosts
  composer [opts] ...    run Composer with the site's PHP (--site HOST | --php VER)
  ssl {enable|disable|status|renew}   trusted HTTPS for all sites
  phpmyadmin [status|install]         optional phpMyAdmin at https://phpmyadmin.test
  php [status|list|default VER]       show or set the default PHP for the 'php' command
  migrate [--source ...] [--apply]    import sites from XAMPP/WAMP/Laragon/Herd
  migrate db <file> [--engine ...]    import a mysqldump/pg_dump into dev-stack
  update [--check|--json|--refresh]   check for a new release
  update --rollback       restore the previous version
  doctor                 verify binaries, services, configs, helper, sites
  version                print version

Modules: mysql postgres redis mail php85 php83 php74 apache web
"@
}

# ---------------------------------------------------------------- dispatch
$argv = @($args)
if ($argv.Count -eq 0) { $argv = @('status') }
$cmd = [string]$argv[0]
$rest = @()
if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

switch ($cmd) {
    'status' { Show-Status }
    'list' { Get-ModuleOrder | ForEach-Object { Write-Host $_ } }
    'start' { Invoke-Start -Target ([string]($rest | Select-Object -First 1)); Show-Status }
    'stop' { Invoke-Stop -Target ([string]($rest | Select-Object -First 1)); Show-Status }
    'restart' { Invoke-Restart -Target ([string]($rest | Select-Object -First 1)); Show-Status }
    'sites' { Show-Sites }
    'add-site' { Add-Site }
    'sync' { Invoke-Sync }
    'composer' { Invoke-Composer -Arguments $rest }
    'ssl' { Invoke-Ssl -Arguments $rest }
    'phpmyadmin' { Invoke-PhpMyAdmin -Arguments $rest }
    'php' { Invoke-Php -Arguments $rest }
    'migrate' { Invoke-Migrate -Arguments $rest }
    'update' { Invoke-Update -Arguments $rest }
    'doctor' { $rc = Invoke-Doctor; if ($rc -ne 0) { exit 1 } }
    'version' { Write-Host "devstack $(Get-DevStackVersion)" }
    '-v' { Write-Host "devstack $(Get-DevStackVersion)" }
    '--version' { Write-Host "devstack $(Get-DevStackVersion)" }
    '-h' { Show-Usage }
    '--help' { Show-Usage }
    'help' { Show-Usage }
    default { Show-Usage; exit 2 }
}
