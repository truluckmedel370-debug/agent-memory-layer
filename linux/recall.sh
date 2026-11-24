#!/usr/bin/env bash
# recall.sh —— 一次调用输出记忆快照（替代逐个读 4 个文件，省 3 次往返）
# 用法：./recall.sh [-l|--log-lines 15] [--full] [-h|--help]

set -euo pipefail

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节
LOG_LINES=15
FULL=0

usage() {
  cat <<'EOF'
用法：recall.sh [选项]

选项：
  -l, --log-lines <N>   输出 LOG.md 尾部 N 行（默认 15）
      --full            输出 LOG.md 全文
  -h, --help            显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--log-lines)
      LOG_LINES="${2:-15}"
      shift 2
      ;;
    --full)
      FULL=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "!! 未知参数：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${AMEM_ROOT:-}" ]]; then
  ROOT="$AMEM_ROOT"
elif [[ -f "$SCRIPT_DIR/MEMORY.md" || -f "$SCRIPT_DIR/LOG.md" ]]; then
  ROOT="$SCRIPT_DIR"
elif [[ -f "$(dirname "$SCRIPT_DIR")/MEMORY.md" || -f "$(dirname "$SCRIPT_DIR")/LOG.md" ]]; then
  ROOT="$(dirname "$SCRIPT_DIR")"
else
  ROOT="$PWD"
fi

read_memo() {
  local p="$ROOT/$1"
  if [[ -f "$p" ]]; then
    tr -d '\r' < "$p"
  fi
}

trim_end() {
  local s="$1"
  # 去掉末尾多余空行与空白
  printf '%s' "$s" | awk '{ lines[NR]=$0 } END { while (NR>0 && lines[NR] ~ /^[[:space:]]*$/) NR--; for (i=1; i<=NR; i++) print lines[i] }'
}

char_len() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo 0
    return
  fi
  local py=""
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)" >/dev/null 2>&1; then
      py="$cand"
      break
    fi
  done
  if [[ -n "$py" ]]; then
    printf '%s' "$s" | "$py" -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))'
  else
    LC_ALL=C.UTF-8 printf '%s' "$s" | wc -m | tr -d '[:space:]'
  fi
}

MEM="$(read_memo 'MEMORY.md')"
PEND="$(read_memo 'PENDING.md')"
INB="$(read_memo 'INBOX.md')"
LOG="$(read_memo 'LOG.md')"

if [[ -z "$MEM" ]]; then
  MEM_LINES=0
else
  MEM_LINES="$(printf '%s\n' "$MEM" | wc -l | tr -d '[:space:]')"
fi

INBOX_COUNT="$(printf '%s\n' "$INB" | grep -c '^- \[ \]' || true)"

echo "===== MEMORY.md（${MEM_LINES} 行）====="
trim_end "$MEM"
echo ""
echo "===== PENDING.md ====="
trim_end "$PEND"
echo ""
echo "===== INBOX.md（待合并 ${INBOX_COUNT} 条）====="
if [[ "$INBOX_COUNT" -gt 0 ]]; then
  trim_end "$INB"
else
  echo "（空）"
fi
echo ""
echo "===== LOG.md 最新 ${LOG_LINES} 行 ====="
if [[ "$FULL" -eq 1 ]]; then
  LOG_OUT="$LOG"
else
  LOG_OUT="$(printf '%s\n' "$LOG" | tail -n "$LOG_LINES")"
fi
trim_end "$LOG_OUT"
echo ""

LEN_MEM="$(char_len "$MEM")"
LEN_PEND="$(char_len "$PEND")"
LEN_INB="$(char_len "$INB")"
LEN_LOG="$(char_len "$LOG_OUT")"
CHARS=$((LEN_MEM + LEN_PEND + LEN_INB + LEN_LOG))

TOK_LOW="$(awk -v c="$CHARS" 'BEGIN { printf "%.0f", c / 1.6 }')"
TOK_HIGH="$(awk -v c="$CHARS" 'BEGIN { printf "%.0f", c / 1.2 }')"

echo "[快照 ${CHARS} 字符，约 ${TOK_LOW}-${TOK_HIGH} token；MEMORY 预算 90 行，现在 ${MEM_LINES} 行]"
if [[ "$MEM_LINES" -gt 90 ]]; then
  echo "!! MEMORY 超预算：先把重复条目合并，再写新的"
fi
