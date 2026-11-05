# TunBox HarmonyOS - Mihomo core cross-compile script (PowerShell, ASCII-only)
# NOTE: keep this file ASCII-only. PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a
#       Chinese comment with odd UTF-8 byte count eats the trailing CR and
#       merges the next line into the comment.
# Output: entry\libs\arm64-v8a\libgojni.so (ohos arm64, musl, c-shared, tags: with_gvisor,cmfa)
#
# Keep upstream outbound capabilities. Raw profiles can use protocols with no
# ArkTS UI references; compiling them out rejects the entire subscription.
#
# Kernel source of record: mihomo-build\mihomo-smart-<sha>\ (vernesong/mihomo,
# branch Alpha; 462455136157a760937c666bba71afe33b1a809e = upstream mihomo v1.19.33
# stable code + Smart group layer). It already contains the TunBox layer in-tree:
#   bridge\bridge.go, bridge\bridge_test.go, cshared_main.go,
#   the REALITY legacy-negotiation patch (component\tls\reality*.go),
#   the sniffer/tuic SetDeadline patches, and
#   `replace github.com/metacubex/gvisor => ../gvisor-patched`.
# Nothing is injected at build time: the build compiles the tree as committed.
$ErrorActionPreference = 'Stop'

# Resolve project-relative paths so the recipe remains reproducible after moving
# or cloning the repository. Environment variables allow CI/local overrides.
$ProjRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $ProjRoot
$SrcDir = $env:MIHOMO_SRC
if (-not $SrcDir) {
  $buildRoot = Join-Path $RepoRoot 'mihomo-build'
  $candidates = @(Get-ChildItem -LiteralPath $buildRoot -Directory -Filter 'mihomo-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'go.mod') })
  if ($candidates.Count -eq 0) {
    Write-Error 'Mihomo source not found. Set MIHOMO_SRC to a source directory containing go.mod.'
    exit 1
  }
  # Deterministic pick: the integrated mihomo-smart tree is the kernel of record.
  # If it is absent we still fail loudly rather than silently compiling a stale tree.
  $preferred = @($candidates | Where-Object { $_.Name -like 'mihomo-smart-*' })
  if ($preferred.Count -eq 1) {
    $SrcDir = $preferred[0].FullName
  } elseif ($preferred.Count -gt 1) {
    Write-Error "Ambiguous mihomo-smart source trees: $(($preferred | ForEach-Object { $_.Name }) -join ', '). Set MIHOMO_SRC explicitly."
    exit 1
  } else {
    Write-Error "No mihomo-smart-* source tree under $buildRoot. Expected the mihomo-smart kernel of record; set MIHOMO_SRC to override."
    exit 1
  }
}

$SdkNative = $env:OHOS_NDK
if (-not $SdkNative) {
  $SdkNative = Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0\native'
}
$NdkClang = (Join-Path $SdkNative 'llvm\bin\clang.exe').Replace('\', '/')
$NdkClangxx = (Join-Path $SdkNative 'llvm\bin\clang++.exe').Replace('\', '/')
$NdkSysroot = (Join-Path $SdkNative 'sysroot').Replace('\', '/')
$GoRoot = $env:OHOS_GOROOT
if (-not $GoRoot) {
  $GoRoot = Join-Path $env:USERPROFILE 'ohos-go-build\ohos_golang_go'
}
$GoExe = Join-Path $GoRoot 'bin\go.exe'
$OutDir = Join-Path $ProjRoot 'entry\libs\arm64-v8a'
$LogDir = Join-Path $env:LOCALAPPDATA 'Temp'

if (-not (Test-Path $NdkClang)) { Write-Error "NDK clang not found: $NdkClang"; exit 1 }
if (-not (Test-Path $GoExe)) { Write-Error "OpenHarmony Go not found: $GoExe"; exit 1 }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Guard: hvigor packages every .so under entry\libs\<abi>\, not just the one this
# recipe writes. A leftover backup (e.g. libgojni.so.bak-<sha>) therefore ships a
# second, stale kernel inside the HAP. Fail loudly instead of silently doubling it.
$stray = @(Get-ChildItem -LiteralPath $OutDir -File -Filter '*.so' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne 'libgojni.so' })
if ($stray.Count -gt 0) {
  $names = ($stray | ForEach-Object { $_.Name }) -join ', '
  Write-Error "Unexpected extra .so in $OutDir (would be packaged into the HAP): $names. Remove or move them out of entry\libs."
  exit 1
}

$env:GOROOT = $GoRoot
$env:GOTOOLCHAIN = 'local'
$env:Path = "$GoRoot\bin;$(Join-Path $SdkNative 'llvm\bin');$env:Path"
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
$env:CGO_ENABLED = '1'
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:GOFLAGS = '-trimpath'
$env:GOMAXPROCS = '1'
$env:CC = '"' + $NdkClang + '" --target=aarch64-linux-ohos "--sysroot=' + $NdkSysroot + '"'
$env:CXX = '"' + $NdkClangxx + '" --target=aarch64-linux-ohos "--sysroot=' + $NdkSysroot + '"'
$env:CGO_CFLAGS = '--target=aarch64-linux-ohos "--sysroot=' + $NdkSysroot + '" -ftls-model=global-dynamic'
$env:CGO_CPPFLAGS = $env:CGO_CFLAGS
$env:CGO_CXXFLAGS = $env:CGO_CFLAGS

Set-Location $SrcDir
Write-Host "==> building mihomo c-shared for ohos arm64 from $SrcDir ..."
$outLog = Join-Path $LogDir 'tunbox-probe-go-build-out.log'
$errLog = Join-Path $LogDir 'tunbox-probe-go-build-err.log'
$stageDir = Join-Path $LogDir 'tunbox-probe-core-build'
New-Item -ItemType Directory -Force $stageDir | Out-Null
$stageLib = Join-Path $stageDir 'libgojni.so'
$buildStamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$linkFlags = "-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=TunBox-smart-46245513 -X github.com/metacubex/mihomo/constant.BuildTime=$buildStamp"
# Direct native invocation avoids Windows PowerShell Start-Process rebuilding an
# inherited environment containing both HTTPS_PROXY and https_proxy as duplicate keys.
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $GoExe build -p 1 -buildmode=c-shared -tags with_gvisor,cmfa `
  -ldflags $linkFlags -o $stageLib . 1> $outLog 2> $errLog
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($buildExit -ne 0) {
  Write-Host "--- go build failed (exit $buildExit), stderr tail: ---"
  Get-Content $errLog -Tail 30
  exit $buildExit
}
Write-Host '--- build stderr (last lines) ---'
Get-Content $errLog -Tail 5

if ((Get-Item -LiteralPath $stageLib).Length -lt 10000000) {
  throw 'Core output is unexpectedly small; keeping the previous packaged core.'
}
Copy-Item -LiteralPath $stageLib -Destination (Join-Path $OutDir 'libgojni.so') -Force

Write-Host "==> built: $OutDir\libgojni.so"
Get-Item "$OutDir\libgojni.so" | ForEach-Object { "{0} bytes" -f $_.Length }
(Get-FileHash "$OutDir\libgojni.so" -Algorithm SHA256).Hash | Out-File "$OutDir\libgojni.sha256"
Write-Host '==> done'
