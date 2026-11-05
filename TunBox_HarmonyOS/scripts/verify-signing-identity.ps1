param([string]$HapPath = '')
$ErrorActionPreference = 'Stop'
$signer = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'sign-nexus-package.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($signer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Signing script has syntax errors' }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ReleaseIdentity' }, $true)
if ($null -eq $function) { throw 'Release identity validator missing' }
Invoke-Expression $function.Extent.Text
function New-Module {
  return @{ app = @{ bundleName = 'com.tunbox.client'; versionName = '0.8.2'; versionCode = 560; debug = $false; buildMode = 'release'; minAPIVersion = 60101024 } }
}
$m = New-Module
Assert-ReleaseIdentity $m 'com.tunbox.client' '0.8.2' '560'
foreach ($key in @('bundleName', 'versionName', 'versionCode', 'debug', 'buildMode', 'minAPIVersion')) {
  $m = New-Module
  $m.app[$key] = $null
  $caught = $false
  try { Assert-ReleaseIdentity $m 'com.tunbox.client' '0.8.2' '560' } catch { $caught = $true }
  if (-not $caught) { throw "Validator accepted missing or mismatched $key" }
}
foreach ($case in @(
  @{ key = 'bundleName'; value = 'other.bundle' },
  @{ key = 'versionName'; value = '0.8.1' },
  @{ key = 'versionCode'; value = 559 },
  @{ key = 'debug'; value = $true },
  @{ key = 'buildMode'; value = 'debug' }
)) {
  $m = New-Module
  $m.app[$case.key] = $case.value
  $caught = $false
  try { Assert-ReleaseIdentity $m 'com.tunbox.client' '0.8.2' '560' } catch { $caught = $true }
  if (-not $caught) { throw "Validator accepted mismatched $($case.key)" }
}
Write-Output 'PASS actual signing validator: matching release accepted, six missing and five wrong identity fields rejected'
if ($HapPath.Length -gt 0) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $HapPath))
  try {
    $reader = [System.IO.StreamReader]::new($zip.GetEntry('module.json').Open())
    try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
  } finally { $zip.Dispose() }
  $project = Split-Path -Parent $PSScriptRoot
  $app = [IO.File]::ReadAllText((Join-Path $project 'AppScope\app.json5')) | ConvertFrom-Json
  Assert-ReleaseIdentity $module $app.app.bundleName $app.app.versionName ([string]$app.app.versionCode)
  Write-Output 'PASS actual HAP identity matches source bundle/version and release/debug contract'
}
