#!/usr/bin/env bash
# TunBox HarmonyOS - Mihomo 内核交叉编译脚本
# 对应 upstream: scripts/build-android-core.sh（recipe 见 assets/libgojni-source.txt）
#
# 产物: libgojni.so (ohos arm64, c-shared, tags: with_gvisor,cmfa)
# 放入: entry/libs/arm64-v8a/ (HVigor 会打包进 HAP 的 /data/storage/el1/bundle/libs/arm64/)
#
# 内核来源: mihomo-build/mihomo-smart-<sha>/（vernesong/mihomo, 分支 Alpha；
# 462455136157a760937c666bba71afe33b1a809e = 上游 mihomo v1.19.33 稳定版代码 + Smart 组层）。
# 该目录内已含 TunBox 集成层，构建期不注入任何文件:
#   bridge/bridge.go, bridge/bridge_test.go, cshared_main.go,
#   REALITY legacy 协商补丁(component/tls/reality*.go),
#   sniffer/tuic SetDeadline 补丁,
#   `replace github.com/metacubex/gvisor => ../gvisor-patched`。
#
# 依赖:
#   - OpenHarmony 版 Go 工具链(支持 GOOS=openharmony, 见 OHOS_GOROOT)
#   - HarmonyOS NDK (含 aarch64-linux-ohos clang 工具链)
#
# 用法:
#   OHOS_NDK=/path/to/ohos-sdk/native OHOS_GOROOT=/path/to/ohos-go \
#     ./scripts/build-ohos-core.sh [/path/to/mihomo-smart-src]
#
# 说明:
#   Go 官方暂无 GOOS=ohos。OHOS native 运行时为 musl libc + Linux kernel,
#   实测可行路径是 GOOS=openharmony GOARCH=arm64 + NDK musl 工具链做 CC;
#   TLS 必须 -ftls-model=global-dynamic, 否则运行期 TLS 重定位失败。
#   Windows 上请用 build-ohos-core.ps1（同一 recipe）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 内核源码: 显式参数 > MIHOMO_SRC > mihomo-build/mihomo-smart-*
MIHOMO_SRC="${1:-${MIHOMO_SRC:-}}"
if [ -z "$MIHOMO_SRC" ]; then
  MIHOMO_SRC="$(find "$REPO_ROOT/mihomo-build" -maxdepth 1 -type d -name 'mihomo-smart-*' -exec test -f '{}/go.mod' ';' -print | head -n 1)"
fi
if [ -z "$MIHOMO_SRC" ] || [ ! -f "$MIHOMO_SRC/go.mod" ]; then
  echo "ERROR: mihomo-smart source tree not found under $REPO_ROOT/mihomo-build." >&2
  echo "       Pass it as \$1 or set MIHOMO_SRC (must contain go.mod)." >&2
  exit 1
fi

OHOS_NDK="${OHOS_NDK:?set OHOS_NDK to the HarmonyOS NDK native/ directory}"
OHOS_GOROOT="${OHOS_GOROOT:?set OHOS_GOROOT to the OpenHarmony Go toolchain root}"
GO="${GO:-$OHOS_GOROOT/bin/go}"

CC_BIN="${OHOS_NDK}/llvm/bin/aarch64-unknown-linux-ohos-clang"
CC_ARGS=""
if [ ! -x "$CC_BIN" ]; then
  # NDK 版本差异: 尝试通用 clang + target 参数
  CC_BIN="${OHOS_NDK}/llvm/bin/clang"
  CC_ARGS="--target=aarch64-linux-ohos --sysroot=${OHOS_NDK}/sysroot"
fi

OUT_DIR="$PROJ_ROOT/entry/libs/arm64-v8a"
mkdir -p "$OUT_DIR"

# Guard: hvigor packages every .so under entry/libs/<abi>/, not just the one this
# recipe writes. A leftover backup (e.g. libgojni.so.bak-<sha>) therefore ships a
# second, stale kernel inside the HAP. Fail loudly instead of silently doubling it.
STRAY="$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.so' ! -name 'libgojni.so' -print)"
if [ -n "$STRAY" ]; then
  echo "ERROR: unexpected extra .so in $OUT_DIR (would be packaged into the HAP):" >&2
  echo "$STRAY" >&2
  echo "Remove or move them out of entry/libs." >&2
  exit 1
fi

echo "==> building mihomo c-shared for ohos arm64 from $MIHOMO_SRC ..."
cd "$MIHOMO_SRC"

export GOROOT="$OHOS_GOROOT"
export GOTOOLCHAIN=local
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
export CGO_ENABLED=1
export GOOS=openharmony
export GOARCH=arm64
export GOFLAGS=-trimpath
export CC="$CC_BIN ${CC_ARGS}"
export CXX="${OHOS_NDK}/llvm/bin/clang++ ${CC_ARGS}"
export CGO_CFLAGS="${CC_ARGS} -ftls-model=global-dynamic"

"$GO" build \
  -buildmode=c-shared \
  -tags "with_gvisor,cmfa" \
  -ldflags "-s -w -buildid=" \
  -o "$OUT_DIR/libgojni.so" \
  .

echo "==> built: $OUT_DIR/libgojni.so"
sha256sum "$OUT_DIR/libgojni.so" | tee "$OUT_DIR/libgojni.sha256"

echo "==> done"
