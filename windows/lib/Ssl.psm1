#Requires -Version 5.1
# lib/Ssl.psm1 - trusted TLS for *.test sites via mkcert on Windows.
Set-StrictMode -Version Latest

function Get-MkcertExe {
    $scoop = Get-ScoopRoot
    return (Get-ToolPath -Name 'mkcert' -EnvVar 'DEVSTACK_MKCERT' -Fallbacks @(
            (Join-Path $scoop 'apps\mkcert\current\mkcert.exe'),
            (Join-Path $scoop 'shims\mkcert.exe')))
}

function Test-SslEnabled { return ([int](Get-ConfigValue 'SSL') -eq 1) }

function Test-MkcertCa {
    $mkcert = Get-MkcertExe
    if (-not $mkcert) { return $false }
    try {
        $caroot = & $mkcert -CAROOT 2>$null
        if (-not $caroot) { return $false }
        return (Test-Path -LiteralPath (Join-Path $caroot 'rootCA.pem'))
    }
    catch { return $false }
}

function Install-MkcertCa {
    $mkcert = Get-MkcertExe
    if (-not $mkcert) { Die 'mkcert not found - install it with: scoop install mkcert' }
    if (Test-MkcertCa) { Write-Ok 'mkcert CA already present'; return }
    Write-Info 'installing mkcert local CA (trusted in the Windows certificate store)'
    Invoke-Run -FilePath $mkcert -ArgumentList @('-install')
}

function Get-SslSans {
    $sans = @('*.test', 'test')
    foreach ($s in @(Get-Sites)) {
        $sans += $s.Host
        if ($s.Aliases) { $sans += ($s.Aliases -split ',') }
    }
    return ($sans | Where-Object { $_ } | Sort-Object -Unique)
}

function New-DevStackCert {
    $mkcert = Get-MkcertExe
    if (-not $mkcert) { Die 'mkcert not found' }
    $paths = Get-DevStackPaths
    if (Test-DryRun) { Write-Host '  [dry-run] mkcert *.test (re)issue' -ForegroundColor DarkGray; return }
    New-Item -ItemType Directory -Force -Path $paths.CertsDir | Out-Null
    $sans = @(Get-SslSans)
    $argList = @('-cert-file', $paths.Cert, '-key-file', $paths.CertKey) + $sans
    & $mkcert @argList *> $null
    if ($LASTEXITCODE -ne 0) { Die 'mkcert failed to issue a certificate' }
    Write-Ok ("issued cert ({0} SANs) -> {1}" -f $sans.Count, $paths.Cert)
}

function Get-SslSummary {
    if (Test-SslEnabled) { return 'enabled' }
    return 'disabled'
}

function Set-AppUrls {
    param([string]$Scheme)
    foreach ($s in @(Get-Sites)) {
        $proj = Get-ProjectRoot $s.DocRoot
        switch ($s.Kind) {
            'laravel' {
                $envFile = Join-Path $proj '.env'
                if (-not (Test-Path -LiteralPath $envFile)) { continue }
                $url = "${Scheme}://$($s.Host)"
                if (Test-DryRun) { Write-Host "  [dry-run] APP_URL $($s.Host) -> $url" -ForegroundColor DarkGray; continue }
                Backup-File $envFile
                $lines = @(Get-Content -LiteralPath $envFile)
                $found = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^APP_URL=') { $lines[$i] = "APP_URL=$url"; $found = $true }
                }
                if (-not $found) { $lines += "APP_URL=$url" }
                Set-Content -LiteralPath $envFile -Value $lines -Encoding ASCII
                Write-Host "  APP_URL $($s.Host) -> $Scheme"
            }
            'wp' {
                $wp = Get-ToolPath -Name 'wp' -EnvVar 'DEVSTACK_WP' -Fallbacks @((Join-Path (Get-ScoopRoot) 'shims\wp.bat'))
                if (-not $wp) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $s.DocRoot 'wp-config.php'))) { continue }
                if (Test-DryRun) { Write-Host "  [dry-run] wp siteurl $($s.Host) -> $Scheme" -ForegroundColor DarkGray; continue }
                $url = "${Scheme}://$($s.Host)"
                & $wp --path="$($s.DocRoot)" --skip-themes --skip-plugins option update home $url *> $null
                & $wp --path="$($s.DocRoot)" --skip-themes --skip-plugins option update siteurl $url *> $null
                Write-Host "  WP siteurl $($s.Host) -> $Scheme"
            }
            default { }
        }
    }
}
