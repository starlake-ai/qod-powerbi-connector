# Generates the QoD connector icons at every size Power BI requires,
# by high-quality downscaling the official brand mark.
#
# Source artwork (vendored in ./source) comes from the Quack on Demand brand kit:
#   Y:\public\quack-on-demand\assets\public\png\mark-light-512.png
# The mark (not the "QOD" wordmark tile) is used because it stays legible at 16px.
#
# Usage:  powershell -File generate-icons.ps1
Add-Type -AssemblyName System.Drawing

$dir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $dir "source\qod-mark-512.png"
$sizes  = 16, 20, 24, 32, 40, 48, 64, 80

$src = [System.Drawing.Image]::FromFile($source)
try {
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        # Slight inset so the mark isn't flush to the icon edge at small sizes.
        $pad  = [int][Math]::Round($s * 0.06)
        $rect = New-Object System.Drawing.Rectangle($pad, $pad, ($s - 2*$pad), ($s - 2*$pad))
        $g.DrawImage($src, $rect)

        $path = Join-Path $dir "QoD$s.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Host "wrote $path ($s x $s)"
    }
}
finally {
    $src.Dispose()
}
