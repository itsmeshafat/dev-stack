#Requires -Version 5.1
# lib/Update.psm1 - release check + safe self-update on Windows.
# Safety contract: an update only replaces the installed package + app bundle (+ the helper task only
# if its script changed). It never touches config, certs, the hosts file, vhosts, databases or services.
Set-StrictMode -Version Latest

$script:UpdateRepo = $env:DEVSTACK_UPDATE_REPO
if (-not $script:UpdateRepo) { $script:UpdateRepo = 'itsmeshafat/dev-stack' }
$script:UpdateCacheMaxAge = 3600

function Get-UpdateApiUri {
    if ($env:DEVSTACK_UPDATE_API) { return $env:DEVSTACK_UPDATE_API }
    return "https://api.github.com/repos/$($script:UpdateRepo)/releases/latest"
}

function Get-UpdateJson {
    if ($env:DEVSTACK_NO_UPDATE_CHECK -eq '1') { return $null }
    $api = Get-UpdateApiUri
    try {
        if ($api -like 'file://*') {
            $u = [uri]$api
            if (Test-Path -LiteralPath $u.LocalPath) { return (Get-Content -LiteralPath $u.LocalPath -Raw) }
            return $null
        }
        if (Test-Path -LiteralPath $api) { return (Get-Content -LiteralPath $api -Raw) }
        $r = Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 8 -Headers @{
            'User-Agent' = 'devstack-updater'
            'Accept'     = 'application/vnd.github+json'
        }
        return $r.Content
    }
    catch { return $null }
}

function Test-VersionGreater {
    param([string]$A, [string]$B)
    $pa = $A.Split('.')
    $pb = $B.Split('.')
    for ($i = 0; $i -lt 3; $i++) {
        $va = 0
        $vb = 0
        if ($i -lt $pa.Count) { [void][int]::TryParse(($pa[$i] -replace '[^0-9]', ''), [ref]$va) }
        if ($i -lt $pb.Count) { [void][int]::TryParse(($pb[$i] -replace '[^0-9]', ''), [ref]$vb) }
        if ($va -gt $vb) { return $true }
        if ($va -lt $vb) { return $false }
    }
    return $false
}

function Get-UpdateStatus {
    param([string]$Json)
    $current = Get-DevStackVersion
    $latest = ''
    $url = ''
    if ($Json) {
        try {
            $obj = $Json | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'tag_name') { $latest = ([string]$obj.tag_name) -replace '^v', '' }
            if ($obj.PSObject.Properties.Name -contains 'html_url') { $url = [string]$obj.html_url }
        }
        catch { }
    }
    $available = $false
    if ($latest -and (Test-VersionGreater $latest $current)) { $available = $true }
    return [pscustomobject]@{ Current = $current; Latest = $latest; Available = $available; Url = $url }
}

function Invoke-UpdateCheck {
    param([string]$Mode = 'human', [switch]$Refresh)
    $paths = Get-DevStackPaths
    $cache = Join-Path $paths.DataDir 'update-check.json'
    $json = ''
    if (-not $Refresh -and (Test-Path -LiteralPath $cache)) {
        $age = 999999
        try { $age = ((Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime).TotalSeconds } catch { }
        if ($age -lt $script:UpdateCacheMaxAge) { $json = Get-Content -LiteralPath $cache -Raw }
    }
    if (-not $json) {
        $json = Get-UpdateJson
        if ($json) { try { Set-Content -LiteralPath $cache -Value $json -Encoding ASCII } catch { } }
    }
    $st = Get-UpdateStatus -Json $json

    if ($Mode -eq 'json') {
        $avail = 'false'
        if ($st.Available) { $avail = 'true' }
        $obj = [ordered]@{
            current   = $st.Current
            latest    = $st.Latest
            available = ($st.Available -as [bool])
            url       = $st.Url
        }
        return ($obj | ConvertTo-Json -Compress)
    }
    if (-not $json) { Write-Warn 'could not check for updates (offline?)'; return }
    if ($st.Available) { Write-Info "Update available: $($st.Current) -> $($st.Latest)"; Write-Note $st.Url }
    else { Write-Ok "up to date ($($st.Current))" }
}

function Invoke-UpdateApply {
    param([switch]$AssumeYes, [bool]$AllowHelper = $true)
    $paths = Get-DevStackPaths
    $current = Get-DevStackVersion

    Write-Info 'checking for updates'
    $json = Get-UpdateJson
    if (-not $json) { Die 'cannot reach GitHub (no network?)' }
    $obj = $json | ConvertFrom-Json
    $tag = [string]$obj.tag_name
    $latest = $tag -replace '^v', ''
    if (-not $latest) { Die 'could not read the latest release' }
    if (-not (Test-VersionGreater $latest $current)) { Write-Ok "already up to date ($current)"; return }

    $url = $env:DEVSTACK_UPDATE_TARBALL
    if (-not $url) { $url = "https://github.com/$($script:UpdateRepo)/archive/refs/tags/$tag.zip" }

    $ts = Get-Timestamp
    $tmp = Join-Path $paths.DataDir ".update-tmp\$ts"
    $zip = Join-Path $tmp 'release.zip'
    if (Test-DryRun) {
        Write-Host ("  [dry-run] download {0} -> swap package {1} -> {2}" -f $url, $current, $latest) -ForegroundColor DarkGray
        return
    }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Write-Info "downloading $tag"
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180 }
    catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; Die 'download failed' }

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if (-not $src) { Die 'unexpected archive layout' }
    $winSrc = Join-Path $src.FullName 'windows'
    if (-not (Test-Path -LiteralPath $winSrc)) { Die 'archive does not contain the windows tree' }

    $newver = ''
    $commonFile = Join-Path $winSrc 'lib\Common.psm1'
    if (Test-Path -LiteralPath $commonFile) {
        $m = [regex]::Match((Get-Content -LiteralPath $commonFile -Raw), "DevStackVersion\s*=\s*'([^']+)'")
        if ($m.Success) { $newver = $m.Groups[1].Value }
    }
    if ($newver -ne $latest) { Die "version mismatch: archive=$newver tag=$latest" }

    $newDir = $paths.PkgDir + '.new'
    if (Test-Path -LiteralPath $newDir) { Remove-Item -LiteralPath $newDir -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $winSrc -Destination $newDir -Recurse -Force

    $helperChanged = $false
    $newHelper = Join-Path $newDir 'bin\DevStackWeb.ps1'
    $oldHelper = Join-Path $paths.PkgDir 'bin\DevStackWeb.ps1'
    if ((Test-Path -LiteralPath $newHelper) -and (Test-Path -LiteralPath $oldHelper)) {
        $hn = (Get-FileHash -LiteralPath $newHelper -Algorithm SHA256).Hash
        $ho = (Get-FileHash -LiteralPath $oldHelper -Algorithm SHA256).Hash
        if ($hn -ne $ho) { $helperChanged = $true }
    }

    # Hand the swap to a detached process: the running CLI holds files inside pkg, and Windows locks them.
    $swapSrc = Join-Path $PSScriptRoot '..\bin\Update-Swap.ps1'
    if (-not (Test-Path -LiteralPath $swapSrc)) { Die 'Update-Swap.ps1 missing from the package' }
    $swap = Join-Path $env:TEMP "devstack-swap-$ts.ps1"
    Copy-Item -LiteralPath $swapSrc -Destination $swap -Force

    $argString = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $swap + '"'),
        '-PkgDir', ('"' + $paths.PkgDir + '"'),
        '-NewDir', ('"' + $newDir + '"'),
        '-BackupsDir', ('"' + $paths.PkgBackups + '"'),
        '-OldVersion', $current,
        '-NewVersion', $latest,
        '-RebuildApp'
    ) -join ' '
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -WindowStyle Hidden

    Write-Ok "update staged: $current -> $latest"
    Write-Note 'the package is swapped in the background; the app will be rebuilt automatically'
    if ($helperChanged) {
        if ($AllowHelper) {
            Write-Note 'the privileged helper changed - update it with (elevated):'
            Write-Note ("  powershell -File `"" + (Join-Path $paths.PkgDir 'bin\Install-HelperTask.ps1') + "`"")
        }
        else { Write-Host 'HELPER_UPDATE_REQUIRED' }
    }
}

function Invoke-UpdateRollback {
    $paths = Get-DevStackPaths
    if (-not (Test-Path -LiteralPath $paths.PkgBackups)) { Die 'no backups to roll back to' }
    $last = Get-ChildItem -LiteralPath $paths.PkgBackups -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $last) { Die 'no backups to roll back to' }
    if (Test-DryRun) { Write-Host "  [dry-run] roll back to $($last.FullName)" -ForegroundColor DarkGray; return }

    $ts = Get-Timestamp
    $swapSrc = Join-Path $PSScriptRoot '..\bin\Update-Swap.ps1'
    $swap = Join-Path $env:TEMP "devstack-rollback-$ts.ps1"
    Copy-Item -LiteralPath $swapSrc -Destination $swap -Force
    $argString = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $swap + '"'),
        '-PkgDir', ('"' + $paths.PkgDir + '"'),
        '-NewDir', ('"' + $last.FullName + '"'),
        '-BackupsDir', ('"' + $paths.PkgBackups + '"'),
        '-OldVersion', 'rollback',
        '-NewVersion', $last.BaseName,
        '-RebuildApp'
    ) -join ' '
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -WindowStyle Hidden
    Write-Ok "rollback staged to $($last.BaseName)"
}
