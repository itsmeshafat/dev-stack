#Requires -Version 5.1
# lib/Modules.psm1 - the service table and process lifecycle on Windows.
# All services run as the current (unelevated) user; only the hosts file needs the helper.
Set-StrictMode -Version Latest

$script:ModuleOrder = @('mysql', 'postgres', 'redis', 'mail', 'php85', 'php83', 'php74', 'apache', 'web')
$script:StartOrder = @('mysql', 'postgres', 'redis', 'mail', 'php85', 'php83', 'php74', 'apache', 'web')
$script:StopOrder = @('web', 'apache', 'php74', 'php83', 'php85', 'mail', 'redis', 'postgres', 'mysql')

function Get-ModuleOrder { return $script:ModuleOrder }
function Get-ModuleStartOrder { return $script:StartOrder }
function Get-ModuleStopOrder { return $script:StopOrder }

function Test-ValidModule {
    param([string]$Name)
    return ($script:ModuleOrder -contains $Name)
}

function Get-ModuleProcessName {
    param([string]$Name)
    switch ($Name) {
        'mysql'    { return 'mysqld' }
        'postgres' { return 'postgres' }
        'redis'    { return 'redis-server' }
        'mail'     { return 'mailpit' }
        'php85'    { return 'php-cgi' }
        'php83'    { return 'php-cgi' }
        'php74'    { return 'php-cgi' }
        'apache'   { return 'httpd' }
        'web'      { return 'nginx' }
        default    { return $Name }
    }
}

function Get-PhpCgiPort {
    param([string]$Version)
    switch -Wildcard ($Version) {
        '8.5*'  { return 9085 }
        '8.3*'  { return 9083 }
        '7.4*'  { return 9074 }
        default { return 9085 }
    }
}

function Get-PhpVersionTag { param([string]$Version) return ($Version -replace '\.', '') }

function Get-ModulePort {
    param([string]$Name)
    switch ($Name) {
        'mysql'    { return 3306 }
        'postgres' { return 5432 }
        'redis'    { return 6379 }
        'mail'     { return 8025 }
        'php85'    { return 9085 }
        'php83'    { return 9083 }
        'php74'    { return 9074 }
        'apache'   { return [int](Get-ConfigValue 'APACHE_PORT') }
        'web'      { return [int](Get-ConfigValue 'NGINX_PORT') }
        default    { return 0 }
    }
}

function Get-ModuleDetail {
    param([string]$Name)
    switch ($Name) {
        'mysql'    { return '127.0.0.1:3306' }
        'postgres' { return '127.0.0.1:5432' }
        'redis'    { return '127.0.0.1:6379' }
        'mail'     { return 'smtp :1025 / ui :8025' }
        'php85'    { return '127.0.0.1:9085 (php-cgi)' }
        'php83'    { return '127.0.0.1:9083 (php-cgi)' }
        'php74'    { return '127.0.0.1:9074 (php-cgi)' }
        'apache'   { return ('127.0.0.1:{0}' -f (Get-ConfigValue 'APACHE_PORT')) }
        'web'      {
            if ([int](Get-ConfigValue 'SSL') -eq 1) {
                return ('nginx :{0}/:{1}' -f (Get-ConfigValue 'NGINX_PORT'), (Get-ConfigValue 'SSL_PORT'))
            }
            return ('nginx :{0}' -f (Get-ConfigValue 'NGINX_PORT'))
        }
        default    { return '' }
    }
}

function Get-ModuleState {
    param([string]$Name, $Ports = $null)
    $paths = Get-DevStackPaths
    $pidFile = Join-Path $paths.RunDir "$Name.pid"
    $procId = Get-ProcessIdFromFile $pidFile
    if ($procId -gt 0) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc) {
            $expected = Get-ModuleProcessName $Name
            if ($proc.ProcessName -like "$expected*") { return 'running' }
        }
    }
    if ($null -eq $Ports) { $Ports = Get-ListeningPorts }
    $port = Get-ModulePort $Name
    if ($port -gt 0 -and $Ports.Contains($port)) { return 'running' }
    return 'stopped'
}

function Get-StatusRows {
    $ports = Get-ListeningPorts
    $rows = @()
    foreach ($m in $script:ModuleOrder) {
        $rows += [pscustomobject]@{
            Name   = $m
            State  = (Get-ModuleState -Name $m -Ports $ports)
            Detail = (Get-ModuleDetail $m)
        }
    }
    return $rows
}

# ---------------------------------------------------------------- tool resolution
function Get-MySqlExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'mysqld' -EnvVar 'DEVSTACK_MYSQLD' -Fallbacks @(
            (Join-Path $scoop 'apps\mysql\current\bin\mysqld.exe')))
}

function Get-PostgresExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'postgres' -EnvVar 'DEVSTACK_POSTGRES' -Fallbacks @(
            (Join-Path $scoop 'apps\postgresql\current\bin\postgres.exe')))
}

function Get-InitdbExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'initdb' -EnvVar 'DEVSTACK_INITDB' -Fallbacks @(
            (Join-Path $scoop 'apps\postgresql\current\bin\initdb.exe')))
}

function Get-RedisExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'redis-server' -EnvVar 'DEVSTACK_REDIS' -Fallbacks @(
            (Join-Path $scoop 'apps\redis\current\redis-server.exe')))
}

function Get-MailpitExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'mailpit' -EnvVar 'DEVSTACK_MAILPIT' -Fallbacks @(
            (Join-Path $scoop 'apps\mailpit\current\mailpit.exe')))
}

function Get-HttpdExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'httpd' -EnvVar 'DEVSTACK_HTTPD' -Fallbacks @(
            (Join-Path $scoop 'apps\apache\current\bin\httpd.exe')))
}

function Test-FcgidAvailable {
    $httpd = Get-HttpdExe
    if (-not $httpd) { return $false }
    $modules = Join-Path (Split-Path -Parent (Split-Path -Parent $httpd)) 'modules'
    return (Test-Path -LiteralPath (Join-Path $modules 'mod_fcgid.so'))
}

function Get-NginxExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'nginx' -EnvVar 'DEVSTACK_NGINX' -Fallbacks @(
            (Join-Path $scoop 'apps\nginx\current\nginx.exe')))
}

function Get-PhpCgiExe {
    param([string]$Version)
    $scoop = Get-ScoopRoot
    $tag = 'php' + (Get-PhpVersionTag $Version)
    $envVar = 'DEVSTACK_PHP' + (Get-PhpVersionTag $Version)
    $v = [Environment]::GetEnvironmentVariable($envVar)
    if ($v -and (Test-Path -LiteralPath $v)) { return $v }
    # Versioned app paths first: the PATH shim 'php-cgi' always points at the default 8.5 build.
    $paths = @((Join-Path $scoop ("apps\$tag\current\php-cgi.exe")))
    if ($Version -eq '8.5') { $paths += (Join-Path $scoop 'apps\php\current\php-cgi.exe') }
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    if ($Version -eq '8.5') { return (Resolve-Executable -Name 'php-cgi') }
    return $null
}

# ---------------------------------------------------------------- lifecycle
function Start-TrackedProcess {
    param(
        [string]$Name,
        [string]$Exe,
        [string[]]$ArgumentList = @(),
        [int[]]$WaitPorts = @()
    )
    $paths = Get-DevStackPaths
    if (-not $Exe) { Die "$Name executable not found - install it with: scoop install $Name" }
    Add-Log "start $Name"
    if (Test-DryRun) {
        Write-Host ("  [dry-run] start {0} {1}" -f $Exe, ($ArgumentList -join ' ')) -ForegroundColor DarkGray
        return
    }
    New-Item -ItemType Directory -Force -Path $paths.RunDir | Out-Null
    $argString = ConvertTo-ArgString -ArgumentList $ArgumentList
    $proc = Start-Process -FilePath $Exe -ArgumentList $argString -WindowStyle Hidden -PassThru
    Set-ProcessIdFile -Path (Join-Path $paths.RunDir "$Name.pid") -ProcessId $proc.Id
    foreach ($port in $WaitPorts) {
        if (-not (Wait-ForPort -Port $port -TimeoutSec 25)) {
            Write-Warn "$Name did not open port $port (see the log for details)"
            return
        }
    }
    Write-Ok "$Name started (pid $($proc.Id))"
}

function Stop-Module {
    param([string]$Name)
    $paths = Get-DevStackPaths
    $pidFile = Join-Path $paths.RunDir "$Name.pid"
    $procId = Get-ProcessIdFromFile $pidFile
    Add-Log "stop $Name"
    if (Test-DryRun) {
        Write-Host "  [dry-run] stop $Name" -ForegroundColor DarkGray
        return
    }
    $expected = Get-ModuleProcessName $Name
    if (Stop-ProcessTree -ProcessId $procId -ExpectedName $expected) {
        Write-Ok "$Name stopped"
    }
    else {
        Write-Note "$Name was not running"
    }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
}

function Start-MySql {
    $paths = Get-DevStackPaths
    $exe = Get-MySqlExe
    if (-not $exe) { Die 'MySQL (mysqld) not found - install it with: scoop install mysql' }
    $dataDir = Join-Path $paths.Data 'mysql'
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'mysql'))) {
        if (-not (Test-DryRun)) {
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            Write-Info 'initializing MySQL data directory (first run)'
            & $exe --initialize-insecure "--datadir=$dataDir"
        }
    }
    $port = [int](Get-ConfigValue 'MYSQL_PORT')
    Start-TrackedProcess -Name 'mysql' -Exe $exe -ArgumentList @(
        "--datadir=$dataDir", "--port=$port", '--bind-address=127.0.0.1'
    ) -WaitPorts @($port)
}

function Start-Postgres {
    $paths = Get-DevStackPaths
    $exe = Get-PostgresExe
    if (-not $exe) { Die 'PostgreSQL (postgres) not found - install it with: scoop install postgresql' }
    $dataDir = Join-Path $paths.Data 'postgres'
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'PG_VERSION'))) {
        $initdb = Get-InitdbExe
        if (-not $initdb) { Die 'initdb not found (PostgreSQL incomplete)' }
        if (-not (Test-DryRun)) {
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            Write-Info 'initializing PostgreSQL data directory (first run)'
            & $initdb -D $dataDir -U $env:USERNAME -A trust -E UTF8
        }
    }
    $port = [int](Get-ConfigValue 'PG_PORT')
    Start-TrackedProcess -Name 'postgres' -Exe $exe -ArgumentList @(
        '-D', $dataDir, '-p', "$port", '-h', '127.0.0.1'
    ) -WaitPorts @($port)
}

function Start-Redis {
    $exe = Get-RedisExe
    if (-not $exe) { Die 'Redis (redis-server) not found - install it with: scoop install redis' }
    $port = [int](Get-ConfigValue 'REDIS_PORT')
    Start-TrackedProcess -Name 'redis' -Exe $exe -ArgumentList @(
        '--port', "$port", '--bind', '127.0.0.1'
    ) -WaitPorts @($port)
}

function Start-Mailpit {
    $exe = Get-MailpitExe
    if (-not $exe) { Die 'Mailpit not found - install it with: scoop install mailpit' }
    Start-TrackedProcess -Name 'mail' -Exe $exe -ArgumentList @(
        '--smtp', '127.0.0.1:1025', '--listen', '127.0.0.1:8025'
    ) -WaitPorts @(8025)
}

function Start-PhpCgi {
    param([string]$Version, [int]$Port)
    $exe = Get-PhpCgiExe $Version
    if (-not $exe) { Die "PHP $Version (php-cgi) not found - install it with Scoop" }
    $args = @('-b', "127.0.0.1:$Port")
    $ini = Join-Path (Split-Path -Parent $exe) 'php.ini'
    if (Test-Path -LiteralPath $ini) { $args += @('-c', $ini) }
    Start-TrackedProcess -Name ('php' + (Get-PhpVersionTag $Version)) -Exe $exe -ArgumentList $args -WaitPorts @($Port)
}

function Get-ApacheConfPath { return (Join-Path (Get-DevStackPaths).ApacheConf 'httpd.conf') }
function Get-NginxConfPath { return (Join-Path (Get-DevStackPaths).NginxConf 'nginx.conf') }

function Start-Apache {
    $exe = Get-HttpdExe
    if (-not $exe) { Die 'Apache (httpd) not found - install it with: scoop install apache' }
    $conf = Get-ApacheConfPath
    if (-not (Test-Path -LiteralPath $conf)) { Die "missing Apache config $conf - run windows\install.ps1" }
    Start-TrackedProcess -Name 'apache' -Exe $exe -ArgumentList @('-f', $conf) -WaitPorts @([int](Get-ConfigValue 'APACHE_PORT'))
}

function Start-Web {
    $exe = Get-NginxExe
    if (-not $exe) { Die 'nginx not found - install it with: scoop install nginx' }
    $conf = Get-NginxConfPath
    if (-not (Test-Path -LiteralPath $conf)) { Die "missing nginx config $conf - run windows\install.ps1" }
    $prefix = (Get-DevStackPaths).NginxConf
    $ports = @([int](Get-ConfigValue 'NGINX_PORT'))
    if ([int](Get-ConfigValue 'SSL') -eq 1) { $ports += [int](Get-ConfigValue 'SSL_PORT') }
    Start-TrackedProcess -Name 'web' -Exe $exe -ArgumentList @('-p', $prefix, '-c', $conf) -WaitPorts $ports
}

function Start-Module {
    param([string]$Name)
    if ((Get-ModuleState $Name) -eq 'running') { Write-Note "$Name already running"; return }
    switch ($Name) {
        'mysql'    { Start-MySql }
        'postgres' { Start-Postgres }
        'redis'    { Start-Redis }
        'mail'     { Start-Mailpit }
        'php85'    { Start-PhpCgi -Version '8.5' -Port 9085 }
        'php83'    { Start-PhpCgi -Version '8.3' -Port 9083 }
        'php74'    { Start-PhpCgi -Version '7.4' -Port 9074 }
        'apache'   { Start-Apache }
        'web'      { Start-Web }
        default    { Die "unknown module: $Name" }
    }
}

function Restart-Module {
    param([string]$Name)
    Stop-Module $Name
    Start-Module $Name
}

function Restart-Apache {
    # `httpd -k restart` targets a Windows service (Apache2.4), not our foreground process, so apply
    # config changes by recycling the process we started ourselves.
    if ((Get-ModuleState 'apache') -ne 'running') { return }
    if (Test-DryRun) { Write-Host '  [dry-run] restart apache (tracked process)' -ForegroundColor DarkGray; return }
    Stop-Module 'apache'
    Start-Module 'apache'
}

function Reload-Nginx {
    $exe = Get-NginxExe
    $conf = Get-NginxConfPath
    if (-not $exe -or -not (Test-Path -LiteralPath $conf)) { return }
    if ((Get-ModuleState 'web') -ne 'running') { return }
    $prefix = (Get-DevStackPaths).NginxConf
    if (Test-DryRun) { Write-Host '  [dry-run] nginx -s reload' -ForegroundColor DarkGray; return }
    & $exe -p $prefix -c $conf -s reload *> $null
}
