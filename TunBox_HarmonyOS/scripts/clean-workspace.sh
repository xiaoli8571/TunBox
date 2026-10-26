#!/usr/bin/env bash
# ============================================================================
# 收尾清理（每个任务完成后必须执行一次）
#
# 目的：把调试过程中产生的截图 / 布局 dump / 日志清干净，避免本机 Temp、设备
#      /data/local/tmp 与仓库里越积越多，也避免下次排查时误读旧证据。
#
# 约定（新产物一律按此前缀命名，脚本才敢删）：
#   本机  $LOCALAPPDATA\Temp\tunbox-probe-*.json|*.jpeg
#   设备  /data/local/tmp/tunbox-probe-*
#
# 本脚本**只删**约定前缀的产物 + 仓库内构建日志 + hermes scratch 里同前缀文件；
# 绝不触碰：源码、docs/、dist/、签名材料、history 相关目录。
#
# 用法：
#   bash TunBox_HarmonyOS/scripts/clean-workspace.sh          # 清理
#   DRY_RUN=1 bash TunBox_HarmonyOS/scripts/clean-workspace.sh # 只看会删什么
# ============================================================================
set -u

HDC="${HDC:-/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCAL_BASE="${LOCALAPPDATA:-$HOME/AppData/Local}"
TMP_WIN="$LOCAL_BASE/Temp"
SCRATCH="$LOCAL_BASE/hermes/cache/scratch"
DRY_RUN="${DRY_RUN:-0}"

removed=0
skipped=0

remove_matches() {
  local dir="$1"; shift
  [ -d "$dir" ] || return 0
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      printf '  would remove: %s\n' "$f"
    else
      if rm -f -- "$f" 2>/dev/null; then
        printf '  removed: %s\n' "$f"
      else
        printf '  SKIP (in use): %s\n' "$f"
        skipped=$((skipped + 1))
        continue
      fi
    fi
    removed=$((removed + 1))
  done
}

echo "== [1/4] 本机临时产物（$TMP_WIN）=="
remove_matches "$TMP_WIN" "$TMP_WIN"/tunbox-probe-*

echo "== [2/4] Hermes scratch（$SCRATCH）=="
remove_matches "$SCRATCH" "$SCRATCH"/tunbox-probe-*

echo "== [3/4] 仓库内构建日志 =="
remove_matches "$ROOT/TunBox_HarmonyOS" "$ROOT/TunBox_HarmonyOS"/*.log

echo "== [4/4] 设备临时产物（/data/local/tmp）=="
if [ -x "$HDC" ] || command -v "$HDC" >/dev/null 2>&1; then
  if "$HDC" list targets 2>/dev/null | grep -qE '^[0-9]'; then
    if [ "$DRY_RUN" = "1" ]; then
      "$HDC" shell "ls /data/local/tmp/tunbox-probe-* 2>/dev/null" || true
    else
      "$HDC" shell "rm -f /data/local/tmp/tunbox-probe-*" >/dev/null 2>&1 \
        && echo "  removed: /data/local/tmp/tunbox-probe-*" \
        || echo "  SKIP: 设备未就绪（hdc 报错），下次连上后再跑"
    fi
  else
    echo "  SKIP: 没有在线设备"
  fi
else
  echo "  SKIP: 找不到 hdc（设置 HDC=/path/to/hdc 后重跑）"
fi

echo
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN：以上为将被删除的文件，未实际删除。"
else
  echo "清理完成：删除 $removed 项，占用跳过 $skipped 项。"
  echo "提醒：dist/ 只保留当前发布版本；旧版本产物按需手动删。"
fi
