# Build Assets\tunbox.ico from the real logo PNG: BMP frames (16/32/48) for the
# tray + a 256 PNG frame for Explorer. ASCII-safe output only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = 'C:\Worker\TunBox\TunBox-logo\TunBox_AGC_AppIcon_512x512.png'
$dst = 'C:\Worker\TunBox\TunBox-Windows\src\TunBox.App\Assets\tunbox.ico'

function Get-PngBytes([int]$size) {
    $srcImg = [System.Drawing.Image]::FromFile($src)
    try {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($srcImg, 0, 0, $size, $size)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $ms.ToArray()
    } finally { $srcImg.Dispose() }
}

function Get-BmpFrame([int]$size) {
    # 32bpp BGRA bottom-up DIB + empty AND mask
    $srcImg = [System.Drawing.Image]::FromFile($src)
    try {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($srcImg, 0, 0, $size, $size)
        $g.Dispose()
        $header = 40
        $xor = $size * $size * 4
        $and = $size * [math]::Ceiling($size / 32.0) * 4
        $data = New-Object byte[] ($header + $xor + $and)
        # BITMAPINFOHEADER, biHeight doubled for ICO
        [BitConverter]::GetBytes([int]40).CopyTo($data, 0)
        [BitConverter]::GetBytes([int]$size).CopyTo($data, 4)
        [BitConverter]::GetBytes([int]($size * 2)).CopyTo($data, 8)
        [BitConverter]::GetBytes([uint16]1).CopyTo($data, 12)
        [BitConverter]::GetBytes([uint16]32).CopyTo($data, 14)
        for ($y = 0; $y -lt $size; $y++) {
            for ($x = 0; $x -lt $size; $x++) {
                $c = $bmp.GetPixel($x, $size - 1 - $y)
                $off = $header + ($y * $size + $x) * 4
                $data[$off] = $c.B; $data[$off + 1] = $c.G; $data[$off + 2] = $c.R; $data[$off + 3] = $c.A
            }
        }
        $bmp.Dispose()
        return $data
    } finally { $srcImg.Dispose() }
}

$frames = @()
foreach ($s in 16, 32, 48) {
    $d = Get-BmpFrame $s
    $frames += ,@($s, $d)
}
$png = Get-PngBytes 256
$frames += ,@(256, $png)

$out = New-Object System.IO.MemoryStream
# ICONDIR
$out.Write([BitConverter]::GetBytes([uint16]0), 0, 2)
$out.Write([BitConverter]::GetBytes([uint16]1), 0, 2)
$out.Write([BitConverter]::GetBytes([uint16]$frames.Count), 0, 2)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $size = $f[0]; $data = $f[1]
    $w = if ($size -ge 256) { 0 } else { $size }
    $out.WriteByte($w); $out.WriteByte($w)
    $out.WriteByte(0); $out.WriteByte(0)          # colors, reserved
    $out.Write([BitConverter]::GetBytes([uint16]1), 0, 2)   # planes
    $out.Write([BitConverter]::GetBytes([uint16]32), 0, 2)  # bpp
    $out.Write([BitConverter]::GetBytes([uint32]$data.Length), 0, 4)
    $out.Write([BitConverter]::GetBytes([uint32]$offset), 0, 4)
    $offset += $data.Length
}
foreach ($f in $frames) { $out.Write($f[1], 0, $f[1].Length) }
[System.IO.File]::WriteAllBytes($dst, $out.ToArray())
Write-Output ('ico written: ' + (Get-Item $dst).Length + ' bytes, frames=' + $frames.Count)
