# Build TunBox-Setup-<ver>.exe with NSIS: the standard installer experience every
# other Clash client ships (welcome -> dir -> progress -> finish/run).
# Stages a fresh publish, then compiles scripts/installer.nsi via makensis.
# ASCII-only: PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a Chinese comment can eat the next line.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$local = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
$dotnet = if (Test-Path $local) { $local } else { 'dotnet.exe' }
$ver = '0.4.8'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'payload-stage'
$nsisHome = 'C:\Worker\.tools\nsis-3.10'
$makensis = Join-Path $nsisHome 'makensis.exe'

if (-not (Test-Path $makensis)) { Write-Error ('makensis not found at ' + $makensis) }

& $dotnet build-server shutdown 2>&1 | Out-Null
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $dist -Force | Out-Null
& $dotnet publish (Join-Path $root 'src\TunBox.App\TunBox.App.csproj') -c Release -o $stage --nologo -v q
if ($LASTEXITCODE -ne 0) { Write-Error ('app publish failed with exit ' + $LASTEXITCODE) }
foreach ($need in @('TunBox.exe', 'TunBox.Core.dll', 'core\tunbox-core.exe', 'core\Model.bin')) {
  if (-not (Test-Path (Join-Path $stage $need))) {
    Write-Error ('payload missing ' + $need + ' -- the installed app would not work')
  }
}

$out = Join-Path $dist ('TunBox-Setup-' + $ver + '.exe')
$icon = Join-Path $root 'src\TunBox.App\Assets\tunbox.ico'
& $makensis /DSTAGE="$stage" /DOUT="$out" /DICON="$icon" /NOCD (Join-Path $here 'installer.nsi')
if ($LASTEXITCODE -ne 0) { Write-Error ('makensis failed with exit ' + $LASTEXITCODE) }

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
$final = Join-Path $dist ('TunBox-Setup-' + $ver + '.exe')
Write-Output ('installer: ' + $final)
Write-Output ('size: ' + [math]::Round((Get-Item $final).Length / 1MB, 1) + 'MB')
