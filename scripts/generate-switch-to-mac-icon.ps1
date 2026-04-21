param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'icons8-mac-os-480.png'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\switch-to-mac.ico')
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
    param(
        [System.Drawing.RectangleF]$Rectangle,
        [float]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-VisibleBounds {
    param([System.Drawing.Bitmap]$Bitmap)

    $left = $Bitmap.Width
    $top = $Bitmap.Height
    $right = -1
    $bottom = -1

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if ($Bitmap.GetPixel($x, $y).A -gt 8) {
                if ($x -lt $left) { $left = $x }
                if ($x -gt $right) { $right = $x }
                if ($y -lt $top) { $top = $y }
                if ($y -gt $bottom) { $bottom = $y }
            }
        }
    }

    if ($right -lt $left -or $bottom -lt $top) {
        return [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    }

    return [System.Drawing.Rectangle]::new($left, $top, $right - $left + 1, $bottom - $top + 1)
}

function Remove-WhiteHalo {
    param([System.Drawing.Bitmap]$Bitmap)

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $color = $Bitmap.GetPixel($x, $y)
            if ($color.A -eq 0) {
                continue
            }

            $avg = ($color.R + $color.G + $color.B) / 3.0
            $spread = ([Math]::Max($color.R, [Math]::Max($color.G, $color.B)) - [Math]::Min($color.R, [Math]::Min($color.G, $color.B)))

            if ($color.A -lt 255 -and $avg -gt 150 -and $spread -lt 55) {
                $t = [Math]::Min(1.0, ($avg - 185.0) / 70.0)
                $tone = if ($y -lt ($Bitmap.Height * 0.48)) {
                    [System.Drawing.Color]::FromArgb(255, 82, 170, 242)
                }
                else {
                    [System.Drawing.Color]::FromArgb(255, 45, 128, 214)
                }

                $r = [int]([Math]::Round(($color.R * (1.0 - $t)) + ($tone.R * $t)))
                $g = [int]([Math]::Round(($color.G * (1.0 - $t)) + ($tone.G * $t)))
                $b = [int]([Math]::Round(($color.B * (1.0 - $t)) + ($tone.B * $t)))
                $Bitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($color.A, $r, $g, $b))
            }
        }
    }
}

function Repair-SourceEdges {
    param([System.Drawing.Bitmap]$Bitmap)

    $copy = New-Object System.Drawing.Bitmap $Bitmap.Width, $Bitmap.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $copy.SetPixel($x, $y, $Bitmap.GetPixel($x, $y))
        }
    }

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $color = $copy.GetPixel($x, $y)
            if ($color.A -eq 0 -or $color.A -eq 255) {
                continue
            }

            $avg = ($color.R + $color.G + $color.B) / 3.0
            $spread = ([Math]::Max($color.R, [Math]::Max($color.G, $color.B)) - [Math]::Min($color.R, [Math]::Min($color.G, $color.B)))
            if ($avg -lt 140 -or $spread -gt 110) {
                continue
            }

            $sumR = 0
            $sumG = 0
            $sumB = 0
            $count = 0
            for ($dy = -2; $dy -le 2; $dy++) {
                for ($dx = -2; $dx -le 2; $dx++) {
                    if ($dx -eq 0 -and $dy -eq 0) {
                        continue
                    }

                    $nx = $x + $dx
                    $ny = $y + $dy
                    if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $Bitmap.Width -or $ny -ge $Bitmap.Height) {
                        continue
                    }

                    $neighbor = $copy.GetPixel($nx, $ny)
                    if ($neighbor.A -ge 160) {
                        $sumR += $neighbor.R
                        $sumG += $neighbor.G
                        $sumB += $neighbor.B
                        $count++
                    }
                }
            }

            if ($count -gt 0) {
                $Bitmap.SetPixel(
                    $x,
                    $y,
                    [System.Drawing.Color]::FromArgb(
                        $color.A,
                        [int]($sumR / $count),
                        [int]($sumG / $count),
                        [int]($sumB / $count)
                    )
                )
            }
        }
    }
}

function New-RenderedBitmap {
    param(
        [System.Drawing.Bitmap]$SourceBitmap,
        [int]$Size
    )

    $visibleBounds = Get-VisibleBounds -Bitmap $SourceBitmap
    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $cardInset = [Math]::Max(1, [Math]::Round($Size * 0.01))
        $cardRect = [System.Drawing.RectangleF]::new($cardInset, $cardInset, $Size - ($cardInset * 2), $Size - ($cardInset * 2))
        $cardPath = New-RoundedRectanglePath -Rectangle $cardRect -Radius ($Size * 0.21)
        try {
            $cardBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 34, 143, 246))
            try {
                $graphics.FillPath($cardBrush, $cardPath)
            }
            finally {
                $cardBrush.Dispose()
            }
        }
        finally {
            $cardPath.Dispose()
        }

        $logoRect = [System.Drawing.Rectangle]::Round([System.Drawing.RectangleF]::new($Size * 0.10, $Size * 0.08, $Size * 0.80, $Size * 0.80))
        $logoBitmap = New-Object System.Drawing.Bitmap $logoRect.Width, $logoRect.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $logoGraphics = [System.Drawing.Graphics]::FromImage($logoBitmap)
            try {
                $logoGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $logoGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $logoGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $logoGraphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $logoGraphics.Clear([System.Drawing.Color]::Transparent)
                $imageAttributes = New-Object System.Drawing.Imaging.ImageAttributes
                try {
                    $imageAttributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
                    $logoGraphics.DrawImage(
                        $SourceBitmap,
                        ([System.Drawing.Rectangle]::new(0, 0, $logoRect.Width, $logoRect.Height)),
                        $visibleBounds.X,
                        $visibleBounds.Y,
                        $visibleBounds.Width,
                        $visibleBounds.Height,
                        [System.Drawing.GraphicsUnit]::Pixel,
                        $imageAttributes
                    )
                }
                finally {
                    $imageAttributes.Dispose()
                }
            }
            finally {
                $logoGraphics.Dispose()
            }

            for ($ly = 0; $ly -lt $logoBitmap.Height; $ly++) {
                for ($lx = 0; $lx -lt $logoBitmap.Width; $lx++) {
                    $pixel = $logoBitmap.GetPixel($lx, $ly)
                    if ($pixel.A -gt 8) {
                        $logoBitmap.SetPixel($lx, $ly, [System.Drawing.Color]::FromArgb($pixel.A, 255, 255, 255))
                    }
                }
            }

            $graphics.DrawImage($logoBitmap, $logoRect)
        }
        finally {
            $logoBitmap.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
    }

    Remove-WhiteHalo -Bitmap $bitmap
    return $bitmap
}

function Convert-BitmapToIconBytes {
    param([System.Drawing.Bitmap]$Bitmap)

    $size = $Bitmap.Width
    $bytesPerPixel = 4
    $xorStride = $size * $bytesPerPixel
    $andStride = [int]([Math]::Ceiling($size / 32.0) * 4)
    $pixelData = New-Object byte[] ($xorStride * $size)
    $andMask = New-Object byte[] ($andStride * $size)

    for ($y = 0; $y -lt $size; $y++) {
        for ($x = 0; $x -lt $size; $x++) {
            $color = $Bitmap.GetPixel($x, $size - 1 - $y)
            $offset = ($y * $xorStride) + ($x * 4)
            $pixelData[$offset + 0] = $color.B
            $pixelData[$offset + 1] = $color.G
            $pixelData[$offset + 2] = $color.R
            $pixelData[$offset + 3] = $color.A
        }
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        $writer.Write([UInt32]40)
        $writer.Write([Int32]$size)
        $writer.Write([Int32]($size * 2))
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]0)
        $writer.Write([UInt32]($pixelData.Length + $andMask.Length))
        $writer.Write([Int32]0)
        $writer.Write([Int32]0)
        $writer.Write([UInt32]0)
        $writer.Write([UInt32]0)
        $writer.Write($pixelData)
        $writer.Write($andMask)
        $writer.Flush()
        return ,$stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source PNG not found: $SourcePath"
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$iconSizes = @(16, 24, 32, 40, 48, 64, 96, 128)
$sourceBitmap = [System.Drawing.Bitmap]::FromFile($SourcePath)
$entries = @()

try {
    Repair-SourceEdges -Bitmap $sourceBitmap
    foreach ($iconSize in $iconSizes) {
        $rendered = New-RenderedBitmap -SourceBitmap $sourceBitmap -Size $iconSize
        try {
            $entries += [pscustomobject]@{
                Size = $iconSize
                Data = (Convert-BitmapToIconBytes -Bitmap $rendered)
            }
        }
        finally {
            $rendered.Dispose()
        }
    }
}
finally {
    $sourceBitmap.Dispose()
}

$offset = 6 + (16 * $entries.Count)
$stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
$writer = New-Object System.IO.BinaryWriter $stream

try {
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$entries.Count)

    foreach ($entry in $entries) {
        $dim = if ($entry.Size -ge 256) { 0 } else { [byte]$entry.Size }
        $writer.Write($dim)
        $writer.Write($dim)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$entry.Data.Length)
        $writer.Write([UInt32]$offset)
        $offset += $entry.Data.Length
    }

    foreach ($entry in $entries) {
        $writer.Write($entry.Data)
    }
}
finally {
    $writer.Dispose()
    $stream.Dispose()
}

Write-Host "Built icon: $OutputPath"
