#!/usr/bin/env bash
# memo.sh —— 记忆库写入 / 检索（手工读写三个子命令：log / mem / pending）
#
# 用法：
#   ./memo.sh show
#   ./memo.sh search <关键词>
#   ./memo.sh log "<内容>"
#   ./memo.sh mem "<内容>"
#   ./memo.sh pending "<内容>"
# 也兼容参数风格：
#   ./memo.sh --kind log --text "<内容>"
#   ./memo.sh --search "<关键词>"
#   ./memo.sh --show

set -euo pipefail

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节
KIND="log"
TEXT=""
SEARCH=""
SHOW=0

usage() {
  cat <<'EOF'
用法：
  memo.sh [show]                           查看 MEMORY.md 与 PENDING.md
  memo.sh search <关键词>                  在所有 *.md 中检索
  memo.sh log <文本>                       插入到 LOG.md 顶部
  memo.sh mem <文本>                       追加到 MEMORY.md 尾部
  memo.sh pending <文本>                   追加到 PENDING.md 尾部

选项（兼容风格）：
  -k, --kind <log|mem|pending>   写入目标（默认 log）
  -t, --text <文本>              写入内容
  -s, --search <关键词>          检索关键词
      --show                     显示 MEMORY.md 与 PENDING.md
  -h, --help                     显示帮助
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    show)
      SHOW=1
      shift 1
      ;;
    search)
      SEARCH="${2:-}"
      shift $(($# >= 2 ? 2 : 1))
      ;;
    log|mem|pending)
      KIND="$1"
      shift 1
      if [[ $# -gt 0 ]]; then
        case "$1" in
          -k|--kind|-t|--text|-s|--search|--show|-h|--help) ;;
          *)
            TEXT="$1"
            shift 1
            ;;
        esac
      fi
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--kind)
      KIND="${2:-log}"
      shift 2
      ;;
    -t|--text)
      TEXT="${2:-}"
      shift 2
      ;;
    -s|--search)
      SEARCH="${2:-}"
      shift 2
      ;;
    --show)
      SHOW=1
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

case "$KIND" in
  log|mem|pending) ;;
  *)
    echo "!! --kind 仅支持 log | mem | pending，当前：$KIND" >&2
    exit 1
    ;;
esac

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

read_all() {
  local p="$1"
  if [[ -f "$p" ]]; then
    tr -d '\r' < "$p"
  fi
}

if [[ "$SHOW" -eq 1 || ( -z "$TEXT" && -z "$SEARCH" ) ]]; then
  echo "===== MEMORY.md ====="
  read_all "$ROOT/MEMORY.md"
  echo ""
  echo "===== PENDING.md ====="
  read_all "$ROOT/PENDING.md"
  exit 0
fi

if [[ -n "$SEARCH" ]]; then
  shopt -s nullglob
  for f in "$ROOT"/*.md; do
    name="$(basename "$f")"
    i=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      i=$((i + 1))
      line="${line%$'\r'}"
      if printf '%s\n' "$line" | grep -Fqi -- "$SEARCH"; then
        printf '%s:%d: %s\n' "$name" "$i" "$line"
      fi
    done < "$f"
  done
  exit 0
fi

STAMP="$(date '+%Y-%m-%d %H:%M')"

case "$KIND" in
  log)
    P="$ROOT/LOG.md"
    S=""
    if [[ -f "$P" ]]; then
      S="$(tr -d '\r' < "$P")"
    fi
    ENTRY="## ${STAMP}"$'\n'"- ${TEXT}"$'\n\n'
    if printf '%s\n' "$S" | grep -q '^## '; then
      # 在第一个 "## " 行之前插入
      TMP_F="$(mktemp)"
      AMEM_ENTRY="$ENTRY" awk '
        BEGIN { inserted = 0; entry = ENVIRON["AMEM_ENTRY"] }
        !inserted && /^## / {
          printf "%s", entry
          inserted = 1
        }
        { print }
      ' "$P" > "$TMP_F"
      mv "$TMP_F" "$P"
    else
      if [[ -n "$S" && "${S: -1}" != $'\n' ]]; then
        S="${S}"$'\n'
      fi
      printf '%s\n%s' "$S" "$ENTRY" > "$P"
    fi
    echo "已写入 LOG.md 顶部：$STAMP"
    ;;
  mem)
    P="$ROOT/MEMORY.md"
    if [[ -f "$P" && -s "$P" ]]; then
      last_char="$(tail -c 1 "$P" 2>/dev/null || true)"
      if [[ -n "$last_char" && "$last_char" != $'\n' ]]; then
        printf '\n' >> "$P"
      fi
    fi
    printf -- '- %s ｜ %s\n' "$STAMP" "$TEXT" >> "$P"
    echo "已追加到 MEMORY.md 尾部"
    ;;
  pending)
    P="$ROOT/PENDING.md"
    if [[ -f "$P" && -s "$P" ]]; then
      last_char="$(tail -c 1 "$P" 2>/dev/null || true)"
      if [[ -n "$last_char" && "$last_char" != $'\n' ]]; then
        printf '\n' >> "$P"
      fi
    fi
    printf '%s\n' "$TEXT" >> "$P"
    echo "已追加到 PENDING.md"
    ;;
esac
