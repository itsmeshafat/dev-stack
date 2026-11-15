#Requires -Version 5.1
# build-app.ps1 - builds the Windows control app with the in-box .NET Framework compiler (csc.exe),
# so no .NET SDK is required. Generates an icon, compiles DevStack.exe and copies HELP.md.
#   windows\app\build-app.ps1 [-OutDir <path>]   (default: %LOCALAPPDATA%\Programs\DevStack)
param(
    [string]$OutDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\DevStack' }

function New-RoundedPath {
    param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2.0
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Same artwork as app/makeicon.swift: blue -> indigo squircle with a white "server rack" glyph.
function New-IconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList @($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = $Size / 1024.0
    $inset = 44.0 * $s
    $x = $inset
    $y = $inset
    $w = $Size - (2.0 * $inset)
    $h = $w
    $radius = $w * 0.2237

    $shadow = New-RoundedPath $x ($y + 8.0 * $s) $w $h $radius
    $shadowBrush = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::FromArgb(46, 0, 0, 0))
    $g.FillPath($shadowBrush, $shadow)

    $shape = New-RoundedPath $x $y $w $h $radius
    $rectF = New-Object System.Drawing.RectangleF -ArgumentList @($x, $y, $w, $h)
    $blue = [System.Drawing.Color]::FromArgb(255, 59, 112, 250)
    $indigo = [System.Drawing.Color]::FromArgb(255, 92, 48, 209)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList @($rectF, $blue, $indigo, 90.0)
    $g.FillPath($grad, $shape)

    $state = $g.Save()
    $g.SetClip($shape)
    $hRect = New-Object System.Drawing.RectangleF -ArgumentList @($x, $y, $w, ($h * 0.5))
    $hiTop = [System.Drawing.Color]::FromArgb(56, 255, 255, 255)
    $hiClear = [System.Drawing.Color]::FromArgb(0, 255, 255, 255)
    $hi = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList @($hRect, $hiTop, $hiClear, 90.0)
    $g.FillRectangle($hi, $hRect)
    $g.Restore($state)

    $gw = $w * 0.46
    $gh = $gw * 0.82
    $gx = ($Size - $gw) / 2.0
    $gy = ($Size - $gh) / 2.0
    $th = [Math]::Max(1024.0 * 0.030 * $s, 1.0)
    $pen = New-Object System.Drawing.Pen -ArgumentList @([System.Drawing.Color]::White, [float]$th)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $glyph = New-RoundedPath $gx $gy $gw $gh ($gw * 0.14)
    $g.DrawPath($pen, $glyph)
    for ($i = 1; $i -le 2; $i++) {
        $yy = $gy + ($gh * $i / 3.0)
        $g.DrawLine($pen, ($gx + $th / 2.0), $yy, ($gx + $gw - $th / 2.0), $yy)
    }
    $dotR = $th * 0.85
    $dotCx = $gx + $gw - ($gw * 0.17)
    $white = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::White)
    for ($i = 0; $i -lt 3; $i++) {
        $cy = $gy + ($gh * ($i + 0.5) / 3.0)
        $g.FillEllipse($white, ($dotCx - $dotR), ($cy - $dotR), ($dotR * 2), ($dotR * 2))
    }

    $g.Dispose()
    return $bmp
}

function Write-Ico {
    param([string]$IconPath, $Images)
    $fs = [System.IO.File]::Create($IconPath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$Images.Count)
    $offset = 6 + 16 * $Images.Count
    foreach ($img in $Images) {
        $dim = 0
        if ($img.Size -lt 256) { $dim = [int]$img.Size }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$img.Data.Length); $bw.Write([UInt32]$offset)
        $offset += $img.Data.Length
    }
    foreach ($img in $Images) { $bw.Write([byte[]]$img.Data) }
    $bw.Close()
}

function New-AppIcon {
    param([string]$IconPath)
    Add-Type -AssemblyName System.Drawing
    $images = New-Object System.Collections.ArrayList
    foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
        $bmp = New-IconBitmap -Size $size
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        [void]$images.Add([pscustomobject]@{ Size = $size; Data = [byte[]]$ms.ToArray() })
        $bmp.Dispose()
        $ms.Dispose()
    }
    Write-Ico -IconPath $IconPath -Images $images
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    Write-Warning 'csc.exe (.NET Framework) not found - the CLI works, but the app cannot be built.'
    return
}

$icon = Join-Path $here 'AppIcon.ico'
Write-Host '== icon =='
New-AppIcon -IconPath $icon

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$src = Join-Path $here 'DevStackApp.cs'
$outExe = Join-Path $OutDir 'DevStack.exe'

Write-Host '== compile =='
& $csc /nologo /target:winexe /optimize+ "/win32icon:$icon" "/out:$outExe" `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
    "$src"
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)" }

$help = Join-Path (Split-Path -Parent $here) 'docs\HELP.md'
if (Test-Path -LiteralPath $help) { Copy-Item -LiteralPath $help -Destination (Join-Path $OutDir 'HELP.md') -Force }

Write-Host "built: $outExe"
