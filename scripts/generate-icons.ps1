#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Windows backend for scripts/generate-icons.sh - generates the ten macOS
    app-icon sizes from the 1024x1024 master.

.DESCRIPTION
    ImageMagick is the primary implementation (see generate-icons.sh). Windows
    hosts frequently do not have it, and `convert.exe` there is the NTFS
    filesystem converter, NOT ImageMagick - so this script exists as a
    dependency-free fallback built on System.Drawing, which ships with Windows.

    It mirrors generate-icons.sh exactly, including the square-master
    normalisation, so a Windows run and a macOS run produce the same file set.

.PARAMETER SourcePath
    A non-square original artwork to normalise into the square master. When
    omitted, the master is only normalised if it is not already square.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\generate-icons.ps1
#>
[CmdletBinding()]
param(
    [string] $MasterPath,
    [string] $OutputDir,
    [string] $SourcePath,
    [int]    $MasterSize = 1024,
    [double] $Fill       = 0.82
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Locate the repository root ---------------------------------------------
# Derived from this script's own location so it works from any CWD, which
# matters because the .sh wrapper invokes it from the repo root.
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $MasterPath) { $MasterPath = Join-Path $RepoRoot 'RosettaStone\Resources\AppIcon.png' }
if (-not $OutputDir)  { $OutputDir  = Join-Path $RepoRoot 'RosettaStone\Support\AppIcon.appiconset' }

# The ten (filename, pixel size) pairs - size x scale, exactly as Contents.json
# declares them. actool compares the real pixel dimensions against that JSON,
# so these two lists can never be allowed to drift apart.
$Targets = @(
    @{ Name = 'AppIcon-16.png';     Size = 16   },
    @{ Name = 'AppIcon-16@2x.png';  Size = 32   },
    @{ Name = 'AppIcon-32.png';     Size = 32   },
    @{ Name = 'AppIcon-32@2x.png';  Size = 64   },
    @{ Name = 'AppIcon-128.png';    Size = 128  },
    @{ Name = 'AppIcon-128@2x.png'; Size = 256  },
    @{ Name = 'AppIcon-256.png';    Size = 256  },
    @{ Name = 'AppIcon-256@2x.png'; Size = 512  },
    @{ Name = 'AppIcon-512.png';    Size = 512  },
    @{ Name = 'AppIcon-512@2x.png'; Size = 1024 }
)

# --- Load System.Drawing ----------------------------------------------------
# MUST come before the $ARGB / $Bicubic assignments below: PowerShell resolves
# a type literal when the statement that uses it executes, so a [System.Drawing...]
# constant declared above the Add-Type fails with "Unable to find type".
try {
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Error ('System.Drawing could not be loaded, so no fallback resizer is available. ' +
        'Install ImageMagick and re-run, or repair the assembly. ' +
        ('Underlying error: ' + $_.Exception.Message))
    exit 1
}

$ARGB       = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
$Bicubic    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$HiQ        = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$SourceCopy = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy

# --- Drawing helpers --------------------------------------------------------
# CompositingMode.SourceCopy is load-bearing: the default SourceOver composite
# folds the image against whatever is already on the bitmap, which for a 32bpp
# bitmap means premultiplying alpha twice and darkening every soft edge.

function New-Canvas {
    param([int] $Width, [int] $Height)
    # A fresh Format32bppArgb bitmap is zero-initialised, i.e. fully transparent.
    return (New-Object System.Drawing.Bitmap($Width, $Height, $ARGB))
}

function Invoke-Draw {
    param(
        [System.Drawing.Image] $Source,
        [System.Drawing.Bitmap] $Destination,
        [System.Drawing.Rectangle] $Dest
    )
    $g = [System.Drawing.Graphics]::FromImage($Destination)
    try {
        $g.CompositingMode  = $SourceCopy
        $g.InterpolationMode = $Bicubic
        $g.PixelOffsetMode  = $HiQ
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.DrawImage($Source, $Dest)
    } finally {
        $g.Dispose()
    }
}

function Get-ArtworkBox {
    # Scales the source to fit inside (Fill * MasterSize) on its longest edge,
    # preserving aspect ratio exactly. Nothing is ever stretched to fit.
    param([System.Drawing.Image] $Source)
    $fit = $MasterSize * $Fill
    $scale = [Math]::Min($fit / $Source.Width, $fit / $Source.Height)
    $w = [int][Math]::Round($Source.Width * $scale)
    $h = [int][Math]::Round($Source.Height * $scale)
    if ($w -gt $MasterSize) { $w = $MasterSize }
    if ($h -gt $MasterSize) { $h = $MasterSize }
    return @{ W = $w; H = $h }
}

function Save-Png {
    param([System.Drawing.Bitmap] $Bitmap, [string] $Path)
    # Encoding explicitly as PNG guarantees the output format regardless of the
    # input format, and writes no EXIF/ICC profile, so the bytes are reproducible.
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
             Where-Object { $_.FormatID -eq [System.Drawing.Imaging.ImageFormat]::Png.Guid } |
             Select-Object -First 1
    $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
    # CompressionLevel 0 = "no compression" in GDI+, i.e. fastest and lossless.
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
        [System.Drawing.Imaging.Encoder]::Compression, [long]0)
    $Bitmap.Save($Path, $codec, $params)
}

# --- Preflight --------------------------------------------------------------
if (-not (Test-Path $OutputDir -PathType Container)) {
    Write-Error "Error: $OutputDir not found. The appiconset folder must exist."
    exit 1
}

# --- Normalise the master to a square --------------------------------------
# macOS requires every source image in an appiconset to be square: actool
# rejects the whole set otherwise. The upstream CC BY-SA original is 229x353,
# so the artwork is fitted (never stretched) onto a transparent square canvas.
# Fill = 0.82 keeps the art inside the macOS icon squircle, whose flat top edge
# spans roughly the middle 56% of the canvas - art sized to the full canvas
# would have its top and bottom clipped by the rounded corners.
$normalised = $false

$input = $MasterPath
if ($SourcePath) {
    if (-not (Test-Path $SourcePath -PathType Leaf)) {
        Write-Error "Error: source artwork $SourcePath not found."
        exit 1
    }
    $input = $SourcePath
    $normalised = $true
}

if (-not (Test-Path $input -PathType Leaf)) {
    Write-Error ("Error: master icon $input not found. Place the 1024x1024 master " +
                 'at RosettaStone\Resources\AppIcon.png, or pass -SourcePath pointing ' +
                 'at the original artwork.')
    exit 1
}

$src = [System.Drawing.Image]::FromFile($input)
try {
    if ($src.Width -ne $MasterSize -or $src.Height -ne $MasterSize) {
        Write-Host ("Normalising master: {0}x{1} -> {2}x{2} square (fill {3:P0}, aspect preserved)" -f `
            $src.Width, $src.Height, $MasterSize, $Fill)
        $box = Get-ArtworkBox -Source $src
        $art = New-Canvas -Width $box.W -Height $box.H
        Invoke-Draw -Source $src -Destination $art `
                    -Dest (New-Object System.Drawing.Rectangle(0, 0, $box.W, $box.H))
        $master = New-Canvas -Width $MasterSize -Height $MasterSize
        $ox = [int][Math]::Floor(($MasterSize - $box.W) / 2)
        $oy = [int][Math]::Floor(($MasterSize - $box.H) / 2)
        Invoke-Draw -Source $art -Destination $master `
                    -Dest (New-Object System.Drawing.Rectangle($ox, $oy, $box.W, $box.H))
        $art.Dispose()
        Save-Png -Bitmap $master -Path $MasterPath
        $master.Dispose()
        $normalised = $true
    }
} finally {
    $src.Dispose()
}

if ($normalised) {
    Write-Host "Wrote square master to $MasterPath"
}

# --- Generate ---------------------------------------------------------------
# Downscaling in repeated halvings rather than one large jump is what keeps the
# 16x16 readable: a single 1024->16 reduction averages ~64 source pixels into
# each output pixel, and a bicubic kernel cannot represent that, so the thin
# white glyph bands alias into noise. Each halving is a ~2x reduction, which
# every filter handles cleanly.
$masterImg = [System.Drawing.Image]::FromFile($MasterPath)
try {
    if ($masterImg.Width -ne $masterImg.Height) {
        Write-Error "Error: master $MasterPath is $($masterImg.Width)x$($masterImg.Height); it must be square."
        exit 1
    }

    foreach ($t in $Targets) {
        $size = $t.Size
        $cur = New-Canvas -Width $masterImg.Width -Height $masterImg.Height
        Invoke-Draw -Source $masterImg -Destination $cur `
                    -Dest (New-Object System.Drawing.Rectangle(0, 0, $cur.Width, $cur.Height))

        while (($cur.Width / 2) -ge $size -and ($cur.Width / 2) -ge 2) {
            $half = New-Object System.Drawing.Bitmap(
                [int]($cur.Width / 2), [int]($cur.Height / 2), $ARGB)
            Invoke-Draw -Source $cur -Destination $half `
                        -Dest (New-Object System.Drawing.Rectangle(0, 0, $half.Width, $half.Height))
            $cur.Dispose()
            $cur = $half
        }

        if ($cur.Width -ne $size -or $cur.Height -ne $size) {
            $final = New-Canvas -Width $size -Height $size
            Invoke-Draw -Source $cur -Destination $final `
                        -Dest (New-Object System.Drawing.Rectangle(0, 0, $size, $size))
            $cur.Dispose()
            $cur = $final
        }

        Save-Png -Bitmap $cur -Path (Join-Path $OutputDir $t.Name)
        $cur.Dispose()
        Write-Host ("  {0,-22} {1}x{1}" -f $t.Name, $size)
    }
} finally {
    $masterImg.Dispose()
}

Write-Host "Generated all icon sizes in $OutputDir"

# --- Verify -----------------------------------------------------------------
# Every file the committed Contents.json references must exist AND be exactly
# the declared pixel size. actool compares real dimensions against the JSON and
# fails the build on a mismatch, so checking existence alone is not enough.
$failed = $false
foreach ($t in $Targets) {
    $path = Join-Path $OutputDir $t.Name
    if (-not (Test-Path $path -PathType Leaf)) {
        Write-Host ("Error: {0} is missing." -f $path)
        $failed = $true
        continue
    }
    $img = [System.Drawing.Image]::FromFile($path)
    $dims = "{0}x{1}" -f $img.Width, $img.Height
    $img.Dispose()
    if ($dims -ne "$($t.Size)x$($t.Size)") {
        Write-Host ("Error: {0} is {1}, expected {2}x{2}." -f $path, $dims, $t.Size)
        $failed = $true
    } else {
        Write-Host ("  OK  {0,-22} {1}" -f $t.Name, $dims)
    }
}

if ($failed) { exit 1 }
Write-Host "Verified: all 10 icon files present and correctly sized."