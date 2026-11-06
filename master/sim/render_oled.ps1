# Render the GDDRAM captured by tb_oled (not an artist's mock-up).
param([string]$HexPath = (Join-Path $PSScriptRoot 'build\oled_screen.hex'),
      [string]$PngPath = (Join-Path $PSScriptRoot 'build\oled_preview.png'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$bytes = @(Get-Content -LiteralPath $HexPath |
    Where-Object { $_ -match '^[0-9A-Fa-f]{2}$' } |
    ForEach-Object { [Convert]::ToByte($_,16) })
if ($bytes.Count -ne 512) { throw 'Expected 512 bytes of 128x32 OLED GDDRAM' }
$scale = 6
$bitmap = [Drawing.Bitmap]::new(128*$scale,32*$scale)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(110,220,255))
try {
    $graphics.Clear([Drawing.Color]::FromArgb(5,12,16))
    for ($y=0; $y -lt 32; $y++) {
        for ($x=0; $x -lt 128; $x++) {
            $index = [int][Math]::Floor($y/8)*128+$x
            if (($bytes[$index] -band (1 -shl ($y%8))) -ne 0) {
                $graphics.FillRectangle($brush,$x*$scale,$y*$scale,$scale,$scale)
            }
        }
    }
    $bitmap.Save($PngPath,[Drawing.Imaging.ImageFormat]::Png)
    Write-Output $PngPath
} finally {
    $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
