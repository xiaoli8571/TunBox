# Publish the Windows client as a directory (NOT single-file):
# CoreHost looks for core\tunbox-core.exe ON DISK; PublishSingleFile would pack it into the exe.
# ASCII-only: PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a Chinese comment can eat the next line.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here                       # ...\TunBox-Windows
$local = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
$dotnet = if (Test-Path $local) { $local } else { 'dotnet.exe' }
$out = Join-Path $root 'publish'

& $dotnet build-server shutdown 2>&1 | Out-Null
& $dotnet publish (Join-Path $root 'src\TunBox.App\TunBox.App.csproj') -c Release -o $out --nologo -v q
if ($LASTEXITCODE -ne 0) { Write-Error ('publish failed with exit ' + $LASTEXITCODE) }

foreach ($f in @('core\tunbox-core.exe', 'core\Model.bin', 'TunBox.exe', 'TunBox.Core.dll')) {
  if (-not (Test-Path (Join-Path $out $f))) { Write-Error ('publish output missing ' + $f) }
}
Write-Output ('published: ' + (Join-Path $out 'TunBox.exe'))
Get-ChildItem $out -Recurse -File | Measure-Object -Property Length -Sum |
  ForEach-Object { 'files=' + (Get-ChildItem $out -Recurse -File).Count + '  size=' +
    [math]::Round($_.Sum / 1MB, 1) + 'MB' }
