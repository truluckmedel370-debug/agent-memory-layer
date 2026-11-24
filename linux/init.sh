#!/usr/bin/env bash
set -euo pipefail
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节

# init.sh —— 把 examples/ 下的模板铺成真正的记忆文件（已存在的不覆盖）
# 用法：
#   ./init.sh                # 铺到仓库根目录
#   ./init.sh --force        # 覆盖已有文件（慎用）
#   ./init.sh --dir ~/mem    # 铺到指定目录
#   ./init.sh -h|--help

usage() {
  cat <<'EOF'
init.sh —— 初始化记忆库（从 examples/ 铺模板）

用法:
  ./init.sh [-f|--force] [-d|--dir <目录>] [-h|--help]

选项:
  -f, --force        覆盖已存在的记忆文件（默认跳过）
  -d, --dir <目录>   目标目录（默认：本脚本所在目录的上一级，即仓库根）
  -h, --help         显示本帮助

说明:
  - 依赖：只需要 bash 的 cp，不需要 python / jq / curl
  - 生成：MEMORY.md / PENDING.md / LOG.md / INBOX.md / ARCHIVE.md / .digest-state.json
  - 下一步：
      ./remember.sh --dry-run
      ./remember.sh
      ./recall.sh
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPL_DIR="$SCRIPT_DIR/../examples"
FORCE=0
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE=1; shift ;;
    -d|--dir)
      [ $# -ge 2 ] || { echo "!! --dir 需要一个参数" >&2; exit 2; }
      DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "!! 未知参数：$1（用 -h 看用法）" >&2; exit 2 ;;
  esac
done

[ -d "$TPL_DIR" ] || { echo "!! 找不到模板目录：$TPL_DIR" >&2; exit 2; }
mkdir -p "$DIR"

wrote=0
skipped=0
for name in MEMORY PENDING LOG INBOX ARCHIVE; do
  src="$TPL_DIR/$name.template.md"
  dst="$DIR/$name.md"
  if [ ! -f "$src" ]; then echo "跳过（缺模板）：$name.template.md"; continue; fi
  if [ -f "$dst" ] && [ "$FORCE" -eq 0 ]; then echo "已存在，不动：$name.md"; skipped=$((skipped+1)); continue; fi
  cp "$src" "$dst"
  echo "写入：$name.md"
  wrote=$((wrote+1))
done

state="$DIR/.digest-state.json"
if [ -f "$state" ] && [ "$FORCE" -eq 0 ]; then
  echo "已存在，不动：.digest-state.json"
  skipped=$((skipped+1))
else
  printf '{"processed":0,"lastStamp":"","updatedAt":"%s","model":""}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$state"
  echo "写入：.digest-state.json"
  wrote=$((wrote+1))
fi

echo ""
echo "完成：写入 $wrote 个，跳过 $skipped 个（目录：$DIR）"
echo ""
echo "下一步："
echo "  1) 在 LOG.md 里追加一条 ## 时间戳 段落 + 带 [事实] 的 bullet"
echo "  2) ./remember.sh --dry-run     # 干跑，看会写进 INBOX 什么"
echo "  3) ./remember.sh               # 真跑"
echo "  4) ./recall.sh                 # 看快照"
