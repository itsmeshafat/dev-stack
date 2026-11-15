#Requires -Version 5.1
# lib/Sites.psm1 - parse sites.conf and generate nginx + Apache vhosts on Windows.
# Format (pipe separated; kind and aliases optional):
#   host | docroot | php | kind | aliases
Set-StrictMode -Version Latest

$script:HostPattern = '^[A-Za-z0-9][A-Za-z0-9.-]*$'

function Test-ValidHost { param([string]$HostName) return ($HostName -match $script:HostPattern) }

function Get-HostPattern { return $script:HostPattern }

function Get-Sites {
    $paths = Get-DevStackPaths
    $rows = @()
    if (-not (Test-Path -LiteralPath $paths.SitesConf)) { return $rows }
    foreach ($line in (Get-Content -LiteralPath $paths.SitesConf)) {
        $l = $line.TrimEnd("`r", "`n")
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $parts = $l -split '\|'
        $hostName = ''
        if ($parts.Count -ge 1) { $hostName = $parts[0].Trim() }
        if ($hostName -eq '') { continue }
        if (-not (Test-ValidHost $hostName)) {
            Write-Warn "sites.conf: skipping invalid host '$hostName'"
            continue
        }
        $docroot = ''
        if ($parts.Count -ge 2) { $docroot = $parts[1].Trim() }
        if ($docroot -match '[";]') {
            Write-Warn "sites.conf: skipping $hostName (invalid docroot)"
            continue
        }
        $php = '8.5'
        if ($parts.Count -ge 3 -and $parts[2].Trim() -ne '') { $php = $parts[2].Trim() }
        if ($php -notmatch '^[0-9.]+$') { $php = '8.5' }
        $kind = 'php'
        if ($parts.Count -ge 4 -and $parts[3].Trim() -ne '') { $kind = $parts[3].Trim() }
        $aliases = ''
        if ($parts.Count -ge 5) {
            $clean = @()
            foreach ($a in ($parts[4] -split ',')) {
                $a = $a.Trim()
                if (Test-ValidHost $a) { $clean += $a }
            }
            $aliases = ($clean -join ',')
        }
        $rows += [pscustomobject]@{
            Host    = $hostName
            DocRoot = (Expand-Tilde $docroot)
            Php     = $php
            Kind    = $kind
            Aliases = $aliases
        }
    }
    return $rows
}

function Get-SiteHostNames {
    $names = @()
    foreach ($s in @(Get-Sites)) {
        $names += $s.Host
        if ($s.Aliases) { $names += ($s.Aliases -split ',') }
    }
    return $names
}

function Get-SiteNamesValue {
    param($Site)
    $names = $Site.Host
    if ($Site.Aliases) { $names += ' ' + ($Site.Aliases -replace ',', ' ') }
    return $names
}

# ---------------------------------------------------------------- vhost content
function Get-NginxVhostContent {
    param($Site)
    $np = Get-ConfigValue 'NGINX_PORT'
    $sp = Get-ConfigValue 'SSL_PORT'
    $ap = Get-ConfigValue 'APACHE_PORT'
    $names = Get-SiteNamesValue $Site
    $paths = Get-DevStackPaths

    if ([int](Get-ConfigValue 'SSL') -eq 1) {
        return @"
server {
    listen $np;
    server_name $names;
    return 301 https://`$host`$request_uri;
}
server {
    listen $sp ssl;
    http2 on;
    server_name $names;
    ssl_certificate     "$($paths.Cert)";
    ssl_certificate_key "$($paths.CertKey)";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    location / {
        proxy_pass http://127.0.0.1:$ap;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
"@
    }

    return @"
server {
    listen $np;
    server_name $names;
    location / {
        proxy_pass http://127.0.0.1:$ap;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_read_timeout 120s;
    }
}
"@
}

function Get-ApacheVhostContent {
    param($Site)
    $ap = Get-ConfigValue 'APACHE_PORT'
    $fcgiPort = Get-PhpCgiPort $Site.Php
    $phpCgi = Get-PhpCgiExe $Site.Php
    $paths = Get-DevStackPaths
    $logDir = Join-Path $paths.LogsDir 'apache'
    $docroot = $Site.DocRoot
    $aliasLine = ''
    if ($Site.Aliases) { $aliasLine = '    ServerAlias ' + ($Site.Aliases -replace ',', ' ') + "`r`n" }

    # mod_fcgid handles Windows paths correctly (php-cgi via proxy_fcgi rejects the "C:" path Apache
    # builds). Fall back to proxy_fcgi only if a php-cgi executable cannot be located.
    if ($phpCgi -and (Test-FcgidAvailable)) {
        $wrapper = $phpCgi -replace '\\', '/'
        $phpBlock = @"
    <FilesMatch \.php`$>
        SetHandler fcgid-script
    </FilesMatch>
    FcgidWrapper "$wrapper" .php
"@
    }
    else {
        $phpBlock = @"
    <FilesMatch \.php`$>
        SetHandler "proxy:fcgi://127.0.0.1:$fcgiPort"
    </FilesMatch>
"@
    }

    return @"
<VirtualHost *:$ap>
    ServerName $($Site.Host)
$aliasLine    DocumentRoot "$docroot"
    <Directory "$docroot">
        Options -Indexes +FollowSymLinks +ExecCGI
        AllowOverride All
        Require all granted
    </Directory>
    DirectoryIndex index.php index.html index.htm
    ErrorLog "$logDir\$($Site.Host)-error.log"
    CustomLog "$logDir\$($Site.Host)-access.log" combined
$phpBlock
</VirtualHost>
"@
}

# ---------------------------------------------------------------- sync
function Sync-Sites {
    $paths = Get-DevStackPaths
    $nginxDir = Join-Path $paths.NginxConf 'servers'
    $apacheDir = Join-Path $paths.ApacheConf 'vhosts'
    $logDir = Join-Path $paths.LogsDir 'apache'

    if (-not (Test-DryRun)) {
        foreach ($d in @($nginxDir, $apacheDir, $logDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    $sites = @(Get-Sites)
    $changedNginx = $false
    $changedApache = $false
    $desiredNginx = @{}
    $desiredApache = @{}

    foreach ($s in $sites) {
        $desiredNginx[$s.Host] = Get-NginxVhostContent $s
        $desiredApache[$s.Host] = Get-ApacheVhostContent $s
    }

    foreach ($s in $sites) {
        $nginxPath = Join-Path $nginxDir ($s.Host + '.conf')
        if (Update-FileIfChanged -Path $nginxPath -Content $desiredNginx[$s.Host]) { $changedNginx = $true }
        $apachePath = Join-Path $apacheDir ($s.Host + '.conf')
        if (Update-FileIfChanged -Path $apachePath -Content $desiredApache[$s.Host]) { $changedApache = $true }
        Write-Host ("  vhost {0,-22} -> {1} (php {2})" -f $s.Host, $s.DocRoot, $s.Php)
    }

    if (-not (Test-DryRun)) {
        if (Test-Path -LiteralPath $nginxDir) {
            Get-ChildItem -LiteralPath $nginxDir -Filter '*.conf' -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $desiredNginx.ContainsKey($_.BaseName)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    $changedNginx = $true
                }
            }
        }
        if (Test-Path -LiteralPath $apacheDir) {
            Get-ChildItem -LiteralPath $apacheDir -Filter '*.conf' -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $desiredApache.ContainsKey($_.BaseName)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    $changedApache = $true
                }
            }
        }
    }

    return [pscustomobject]@{ NginxChanged = $changedNginx; ApacheChanged = $changedApache }
}

# ---------------------------------------------------------------- base configs
function Get-NginxMimeTypesPath {
    $exe = Get-NginxExe
    if (-not $exe) { return $null }
    $cand = Join-Path (Split-Path -Parent $exe) 'conf\mime.types'
    if (Test-Path -LiteralPath $cand) { return $cand }
    return $null
}

function Get-NginxBaseConfig {
    $paths = Get-DevStackPaths
    $np = Get-ConfigValue 'NGINX_PORT'
    $errLog = Join-Path $paths.LogsDir 'nginx-error.log'
    $pidFile = Join-Path $paths.RunDir 'nginx.pid'
    $mime = Get-NginxMimeTypesPath
    $mimeLine = ''
    if ($mime) { $mimeLine = '    include "' + ($mime -replace '\\', '/') + '";' }
    return @"
# dev-stack managed nginx config (Windows) - regenerated by devstack sync / install
worker_processes  auto;
error_log  "$($errLog -replace '\\','/')" warn;
pid        "$($pidFile -replace '\\','/')";

events { worker_connections 1024; }

http {
$mimeLine
    default_type  application/octet-stream;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    client_max_body_size 256M;
    server_names_hash_bucket_size 64;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    server { listen $np default_server; server_name _; return 404; }

    include servers/*.conf;
}
"@
}

function Get-ApacheBaseConfig {
    $paths = Get-DevStackPaths
    $ap = Get-ConfigValue 'APACHE_PORT'
    $apacheDir = $paths.ApacheConf
    $vhosts = Join-Path $apacheDir 'vhosts'
    $www = Join-Path $paths.Data 'www'
    $errLog = Join-Path $paths.LogsDir 'apache-error.log'
    $pidFile = Join-Path $paths.RunDir 'httpd.pid'
    $types = Join-Path $apacheDir 'mime.types'

    $httpd = Get-HttpdExe
    $moduleDir = ''
    if ($httpd) {
        $binDir = Split-Path -Parent $httpd
        $root = Split-Path -Parent $binDir
        $cand = Join-Path $root 'modules'
        if (Test-Path -LiteralPath $cand) { $moduleDir = $cand }
    }
    # The MPM is compiled into httpd.exe in Apache Lounge's Windows builds - do NOT LoadModule an MPM.
    $mods = @('authn_core', 'authz_host', 'authz_core', 'access_compat', 'filter',
        'deflate', 'mime', 'log_config', 'env', 'headers', 'setenvif', 'version',
        'proxy', 'proxy_http', 'dir', 'alias', 'rewrite')
    if (Test-FcgidAvailable) { $mods += 'fcgid' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $mods) {
        if ($moduleDir) {
            [void]$sb.AppendLine("LoadModule ${m}_module `"$moduleDir\mod_$m.so`"")
        }
        else {
            [void]$sb.AppendLine("LoadModule ${m}_module `"modules/mod_$m.so`"")
        }
    }
    $loadModules = $sb.ToString().TrimEnd()

    return @"
# dev-stack managed Apache config (Windows) - regenerated by devstack sync / install
ServerRoot "$apacheDir"
Listen 127.0.0.1:$ap
ServerName 127.0.0.1:$ap
PidFile "$pidFile"
ErrorLog "$errLog"
LogLevel warn
LogFormat "%h %l %u %t \"%r\" %>s %b" combined
TypesConfig "$types"

$loadModules

<IfModule mod_fcgid.c>
    FcgidMaxRequestsPerProcess 1000
    FcgidIOTimeout 120
    FcgidBusyTimeout 120
    FcgidIdleTimeout 300
    FcgidInitialEnv REDIRECT_STATUS 200
</IfModule>

DocumentRoot "$www"
<Directory "$www">
    AllowOverride None
    Require all granted
</Directory>
<IfModule dir_module>
    DirectoryIndex index.php index.html index.htm
</IfModule>

IncludeOptional "$vhosts\*.conf"
"@
}

function Write-BaseConfigs {
    $paths = Get-DevStackPaths
    if (-not (Test-DryRun)) {
        foreach ($d in @($paths.NginxConf, (Join-Path $paths.NginxConf 'servers'),
                (Join-Path $paths.NginxConf 'logs'), (Join-Path $paths.NginxConf 'temp'),
                $paths.ApacheConf, (Join-Path $paths.ApacheConf 'vhosts'),
                (Join-Path $paths.Data 'www'), $paths.LogsDir)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
    Update-FileIfChanged -Path (Join-Path $paths.NginxConf 'nginx.conf') -Content (Get-NginxBaseConfig) | Out-Null
    Update-FileIfChanged -Path (Join-Path $paths.ApacheConf 'httpd.conf') -Content (Get-ApacheBaseConfig) | Out-Null
    $types = Join-Path $paths.ApacheConf 'mime.types'
    if (-not (Test-Path -LiteralPath $types)) {
        $httpd = Get-HttpdExe
        if ($httpd) {
            $src = Join-Path (Split-Path -Parent (Split-Path -Parent $httpd)) 'conf\mime.types'
            if ((Test-Path -LiteralPath $src) -and -not (Test-DryRun)) { Copy-Item -LiteralPath $src -Destination $types -Force }
        }
    }
    Write-Ok 'wrote nginx + Apache base configs'
}

function Get-ProjectRoot {
    param([string]$DocRoot)
    if (-not $DocRoot) { return $DocRoot }
    if ((Split-Path -Leaf $DocRoot) -eq 'public') { return (Split-Path -Parent $DocRoot) }
    return $DocRoot
}
