#Requires -Version 5.1
# lib/Common.psm1 - paths, config, logging, dry-run, backups, port/process utilities.
# Sourced (Import-Module) by devstack.ps1, install.ps1 and bin/*.
Set-StrictMode -Version Latest

$script:DevStackVersion = '1.6.0'
$script:DryRun = $false
$script:Quiet = $false
$script:BackupTs = $null

$script:Config = @{
    NGINX_PORT  = 80
    APACHE_PORT = 8081
    SSL_PORT    = 443
    SSL         = 0
    MYSQL_PORT  = 3306
    PG_PORT     = 5432
    REDIS_PORT  = 6379
    PHP_DEFAULT = '8.5'
}

function Get-DevStackVersion { return $script:DevStackVersion }

function Get-DevStackPaths {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $local = $env:LOCALAPPDATA
    if (-not $local) { $local = Join-Path $userHome 'AppData\Local' }
    $data = Join-Path $local 'devstack'
    return [pscustomobject]@{
        Home        = $userHome
        ConfigDir   = Join-Path $userHome '.config\devstack'
        SitesConf   = Join-Path $userHome '.config\devstack\sites.conf'
        ConfigFile  = Join-Path $userHome '.config\devstack\config'
        DataDir     = $data
        Log         = Join-Path $data 'devstack.log'
        BackupDir   = Join-Path $data 'backups'
        CertsDir    = Join-Path $data 'certs'
        RunDir      = Join-Path $data 'run'
        ConfDir     = Join-Path $data 'conf'
        NginxConf   = Join-Path $data 'conf\nginx'
        ApacheConf  = Join-Path $data 'conf\apache'
        LogsDir     = Join-Path $data 'logs'
        Data        = Join-Path $data 'data'
        PkgDir      = Join-Path $data 'pkg'
        PkgBackups  = Join-Path $data 'pkg-backups'
        BinDir      = Join-Path $data 'bin'
        IpcDir      = Join-Path $data 'ipc'
        Cert        = Join-Path $data 'certs\devstack.test.pem'
        CertKey     = Join-Path $data 'certs\devstack.test-key.pem'
        HelperTask  = 'DevStackHelper'
    }
}

function Get-CliShimPath { return (Join-Path (Get-DevStackPaths).BinDir 'devstack.cmd') }

# ---------------------------------------------------------------- state
function Set-DryRun { param([bool]$Value) $script:DryRun = $Value }
function Test-DryRun { return [bool]$script:DryRun }
function Set-Quiet { param([bool]$Value) $script:Quiet = $Value }
function Set-BackupTimestamp { param([string]$Value) $script:BackupTs = $Value }

function Get-Config { return $script:Config }
function Get-ConfigValue { param([string]$Key) return $script:Config[$Key] }

function Get-DefaultPort {
    param([string]$Key)
    switch ($Key) {
        'NGINX_PORT'  { return 80 }
        'APACHE_PORT' { return 8081 }
        'SSL_PORT'    { return 443 }
        'MYSQL_PORT'  { return 3306 }
        'PG_PORT'     { return 5432 }
        'REDIS_PORT'  { return 6379 }
        default       { return 0 }
    }
}

function Load-Config {
    $paths = Get-DevStackPaths
    if (Test-Path -LiteralPath $paths.ConfigFile) {
        foreach ($line in (Get-Content -LiteralPath $paths.ConfigFile)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $i = $t.IndexOf('=')
            if ($i -lt 1) { continue }
            $k = $t.Substring(0, $i).Trim()
            $v = $t.Substring($i + 1).Trim()
            if ($script:Config.ContainsKey($k)) { $script:Config[$k] = $v }
        }
    }
    foreach ($k in @('NGINX_PORT', 'APACHE_PORT', 'SSL_PORT', 'MYSQL_PORT', 'PG_PORT', 'REDIS_PORT', 'SSL')) {
        if ($k -eq 'SSL') {
            $sv = 0
            if (-not [int]::TryParse([string]$script:Config[$k], [ref]$sv)) { $sv = 0 }
            $script:Config[$k] = $sv
        }
        else {
            $iv = 0
            if (-not [int]::TryParse([string]$script:Config[$k], [ref]$iv)) { $iv = Get-DefaultPort $k }
            $script:Config[$k] = $iv
        }
    }
}

function Set-Config {
    param([string]$Key, [string]$Value)
    $paths = Get-DevStackPaths
    if (-not (Test-DryRun)) {
        New-Item -ItemType Directory -Force -Path $paths.ConfigDir | Out-Null
        $lines = @()
        if (Test-Path -LiteralPath $paths.ConfigFile) { $lines = @(Get-Content -LiteralPath $paths.ConfigFile) }
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^' + [regex]::Escape($Key) + '=')) {
                $lines[$i] = "$Key=$Value"
                $found = $true
            }
        }
        if (-not $found) { $lines += "$Key=$Value" }
        Set-Content -LiteralPath $paths.ConfigFile -Value $lines -Encoding ASCII
    }
    $script:Config[$Key] = $Value
}

function Ensure-Dirs {
    $paths = Get-DevStackPaths
    $dirs = @($paths.DataDir, $paths.ConfigDir, $paths.BackupDir, $paths.RunDir, $paths.ConfDir,
        $paths.CertsDir, $paths.LogsDir, $paths.Data, $paths.IpcDir, $paths.BinDir)
    foreach ($d in $dirs) {
        if (Test-DryRun) {
            Write-Host "  [dry-run] mkdir $d" -ForegroundColor DarkGray
        }
        else {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

# ---------------------------------------------------------------- output / logging
function Add-Log {
    param([string]$Message)
    try {
        $paths = Get-DevStackPaths
        if (-not (Test-Path -LiteralPath $paths.DataDir)) { return }
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $paths.Log -Value "$ts $Message [pid=$PID]" -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Write-Info { param([string]$Message) if (-not $script:Quiet) { Write-Host "> $Message" -ForegroundColor Cyan } }
function Write-Note { param([string]$Message) if (-not $script:Quiet) { Write-Host "  $Message" } }
function Write-Ok { param([string]$Message) if (-not $script:Quiet) { Write-Host "[ok] $Message" -ForegroundColor Green } }
function Write-Warn { param([string]$Message) Write-Host "! $Message" -ForegroundColor Yellow }
function Die { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- execution
function Invoke-Run {
    param([string]$FilePath, [string[]]$ArgumentList = @())
    if (Test-DryRun) {
        Write-Host ("  [dry-run] {0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray
        return
    }
    & $FilePath @ArgumentList
}

function ConvertTo-ArgString {
    param([string[]]$ArgumentList = @())
    $parts = foreach ($a in $ArgumentList) {
        if ($a -match '\s') { '"' + $a + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Get-Timestamp { return (Get-Date).ToString('yyyyMMdd-HHmmss') }

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $paths = Get-DevStackPaths
    $ts = $script:BackupTs
    if (-not $ts) { $ts = Get-Timestamp }
    $dest = Join-Path $paths.BackupDir $ts
    if (Test-DryRun) {
        Write-Host "  [dry-run] backup $Path -> $dest" -ForegroundColor DarkGray
        return
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -LiteralPath $Path -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
}

function Update-FileIfChanged {
    param([string]$Path, [string]$Content)
    $existing = $null
    if (Test-Path -LiteralPath $Path) { $existing = Get-Content -LiteralPath $Path -Raw }
    if ($null -ne $existing) {
        $a = ($existing -replace "`r`n", "`n").TrimEnd()
        $b = ($Content -replace "`r`n", "`n").TrimEnd()
        if ($a -eq $b) { return $false }
    }
    if (Test-DryRun) {
        Write-Host "  [dry-run] write $Path" -ForegroundColor DarkGray
        return $true
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
    return $true
}

# ---------------------------------------------------------------- tooling
function Test-Executable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-Executable {
    param([string]$Name, [string[]]$Fallbacks = @())
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($f in $Fallbacks) {
        if ($f -and (Test-Path -LiteralPath $f)) { return $f }
    }
    return $null
}

function Get-ToolPath {
    param([string]$Name, [string]$EnvVar, [string[]]$Fallbacks = @())
    if ($EnvVar) {
        $v = [Environment]::GetEnvironmentVariable($EnvVar)
        if ($v -and (Test-Path -LiteralPath $v)) { return $v }
    }
    # Prefer explicit app paths over PATH shims: Scoop shims for versioned packages can resolve to the
    # wrong major version (notably php-cgi), so the known layout wins when present.
    foreach ($f in $Fallbacks) {
        if ($f -and (Test-Path -LiteralPath $f)) { return $f }
    }
    return (Resolve-Executable -Name $Name)
}

function Get-ScoopRoot {
    if ($env:SCOOP) { return $env:SCOOP }
    $u = [Environment]::GetFolderPath('UserProfile')
    return (Join-Path $u 'scoop')
}

function Expand-Tilde {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -eq '~') { return [Environment]::GetFolderPath('UserProfile') }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return (Join-Path ([Environment]::GetFolderPath('UserProfile')) $Path.Substring(2))
    }
    return $Path
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- ports / processes
function Get-ListeningPorts {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    $ok = $false
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop
        foreach ($c in $conns) { [void]$set.Add([int]$c.LocalPort) }
        $ok = $true
    }
    catch { $ok = $false }

    if (-not $ok) {
        try {
            foreach ($line in (& netstat.exe -ano -p tcp)) {
                if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING') {
                    [void]$set.Add([int]$Matches[1])
                }
            }
        }
        catch { }
    }
    return , $set
}

function Wait-ForPort {
    param([int]$Port, [int]$TimeoutSec = 20)
    if ($Port -le 0) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ListeningPorts).Contains($Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Stop-ProcessTree {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $false }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($ExpectedName -and ($proc.ProcessName -notlike "$ExpectedName*")) { return $false }
    & taskkill.exe /PID $ProcessId /T /F *> $null
    return $true
}

function Get-ProcessIdFromFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $Path -Raw).Trim() } catch { return 0 }
    $id = 0
    if ([int]::TryParse($raw, [ref]$id)) { return $id }
    return 0
}

function Set-ProcessIdFile {
    param([string]$Path, [int]$ProcessId)
    if (Test-DryRun) { return }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $Path -Value $ProcessId -Encoding ASCII
}
