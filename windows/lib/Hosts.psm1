#Requires -Version 5.1
# lib/Hosts.psm1 - the managed hosts block and the privileged helper IPC.
# The hosts file is the ONLY privileged operation on Windows; it is written by the DevStackHelper
# scheduled task (highest privileges), never by the unelevated CLI directly.
Set-StrictMode -Version Latest

$script:HostsBegin = '# devstack-begin'
$script:HostsEnd = '# devstack-end'

function Get-HostsPath { return (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') }

function Get-HostsNames {
    $paths = Get-DevStackPaths
    $dir = Join-Path $paths.NginxConf 'servers'
    $names = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $names }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.conf' -ErrorAction SilentlyContinue)) {
        foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
            if ($line -match '^\s*server_name\s+(.+?);') {
                foreach ($n in ($Matches[1] -split '\s+')) {
                    if ($n -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $names += $n }
                }
            }
        }
    }
    return ($names | Sort-Object -Unique)
}

function Get-DesiredHostsBlock {
    # An empty string means "no managed entries" - Sync-Hosts then removes the block entirely.
    $names = @(Get-HostsNames)
    if ($names.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($script:HostsBegin)
    foreach ($n in $names) { [void]$sb.AppendLine("127.0.0.1 $n") }
    [void]$sb.Append($script:HostsEnd)
    return $sb.ToString()
}

function Test-HostsBlockCurrent {
    $hostsPath = Get-HostsPath
    $desired = Get-DesiredHostsBlock
    if (-not (Test-Path -LiteralPath $hostsPath)) { return ($desired -eq '') }
    $content = Get-Content -LiteralPath $hostsPath -Raw
    if ($null -eq $content) { $content = '' }
    if ($desired -eq '') { return (-not $content.Contains($script:HostsBegin)) }
    $norm = ($content -replace "`r`n", "`n")
    $want = ($desired -replace "`r`n", "`n")
    return $norm.Contains($want)
}

function Sync-Hosts {
    $desired = Get-DesiredHostsBlock
    $hostsPath = Get-HostsPath
    $content = ''
    if (Test-Path -LiteralPath $hostsPath) { $content = Get-Content -LiteralPath $hostsPath -Raw }
    if ($null -eq $content) { $content = '' }

    $pattern = '(?ms)^' + [regex]::Escape($script:HostsBegin) + '.*?^' + [regex]::Escape($script:HostsEnd) + '\r?\n?'
    $stripped = [regex]::Replace($content, $pattern, '')
    $stripped = $stripped.TrimEnd()
    if ($stripped -ne '') { $stripped = $stripped + "`r`n`r`n" }
    $updated = $stripped
    if ($desired -ne '') { $updated = $stripped + $desired + "`r`n" }

    if ($updated -eq $content) { Write-Note 'hosts already up to date'; return }
    # Keep a safety copy of the current hosts before changing it.
    if ($content -ne '') {
        try {
            $paths = Get-DevStackPaths
            New-Item -ItemType Directory -Force -Path $paths.BackupDir | Out-Null
            Set-Content -LiteralPath (Join-Path $paths.BackupDir ('hosts-safety-' + (Get-Timestamp) + '.txt')) -Value $content -Encoding ASCII -NoNewline -ErrorAction SilentlyContinue
        }
        catch { }
    }
    Set-Content -LiteralPath $hostsPath -Value $updated -Encoding ASCII -NoNewline
    & ipconfig.exe /flushdns *> $null
    if ($desired -eq '') { Write-Ok 'cleared dev-stack hosts entries'; return }
    $count = @($desired -split "`r`n" | Where-Object { $_ -match '^127\.0\.0\.1' }).Count
    Write-Ok "synced hosts ($count names)"
}

# ---------------------------------------------------------------- helper IPC
function Get-IpcDirs {
    $paths = Get-DevStackPaths
    $base = Join-Path $paths.IpcDir ''
    return [pscustomobject]@{
        Request = Join-Path $paths.IpcDir 'requests'
        Result  = Join-Path $paths.IpcDir 'results'
    }
}

function Get-HelperTaskName { return (Get-DevStackPaths).HelperTask }

function Test-HelperTask {
    try {
        $t = Get-ScheduledTask -TaskName (Get-HelperTaskName) -ErrorAction SilentlyContinue
        return [bool]$t
    }
    catch { return $false }
}

function Invoke-HelperSyncHosts {
    if (Test-HostsBlockCurrent) { Write-Note 'hosts already up to date'; return $true }

    if (-not (Test-HelperTask)) {
        if (Test-IsElevated) { Sync-Hosts; return $true }
        Write-Warn "helper task '$(Get-HelperTaskName)' is not installed - run windows\install.ps1 (adds it)"
        return $false
    }

    $dirs = Get-IpcDirs
    if (-not (Test-DryRun)) {
        New-Item -ItemType Directory -Force -Path $dirs.Request, $dirs.Result | Out-Null
    }
    $id = [guid]::NewGuid().ToString('N')
    $reqPath = Join-Path $dirs.Request "$id.json"
    $resPath = Join-Path $dirs.Result "$id.json"
    $payload = @{ id = $id; action = 'sync-hosts' } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $reqPath -Value $payload -Encoding ASCII

    & schtasks.exe /run /tn (Get-HelperTaskName) *> $null

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resPath) {
            $res = Get-Content -LiteralPath $resPath -Raw | ConvertFrom-Json
            Remove-Item -LiteralPath $resPath -ErrorAction SilentlyContinue
            if ($res.ok) { Write-Ok 'hosts synced (helper)'; return $true }
            Write-Warn ("helper failed: {0}" -f $res.message)
            return $false
        }
        Start-Sleep -Milliseconds 300
    }
    Write-Warn 'helper did not respond in time (run: devstack sync again)'
    return $false
}
