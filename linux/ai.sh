#!/usr/bin/env bash
# ai.sh —— 本地 Ollama 单次问答（remember.sh 的模型接口层）
#
# 用法：
#   ./ai.sh --prompt "..." [--sys "..."] [--model qwen3-4b:q4] [--max-tok 700] [--temp 0] [--fmt text|json] [--schema '<json>'] [--no-cache yes] [--base http://127.0.0.1:11434] [--timeout 300] [--show-meta]
#
# - --fmt json     → 强制模型输出合法 JSON（Ollama 的 format 字段）
# - --schema <json> → 更强的约束：把整个 JSON Schema 交给 Ollama 当解码语法（推荐，根是数组时必用）
# - --no-cache      → 保留参数（兼容旧调用）；本脚本无缓存层，忽略即可
#
# 依赖：curl + python3/python（或 jq）；Ollama 在 11434 上跑着（没跑就 ollama serve）

set -euo pipefail

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节
PROMPT=""
SYS=""
MODEL=""
MAX_TOK=700
TEMP=0
FMT="text"
NO_CACHE=""
SCHEMA=""
BASE="${AMEM_OLLAMA_BASE:-http://127.0.0.1:11434}"
TIMEOUT_SEC=300
SHOW_META=0

usage() {
  cat <<'EOF'
用法：ai.sh --prompt <文本> [选项]

选项：
  -p, --prompt <文本>     必填，用户提示词
  -s, --sys <文本>        系统提示词
  -m, --model <模型>      模型名（默认：$AMEM_MODEL 或 qwen3-4b:q4）
      --max-tok <N>       最大生成 token 数（默认 700）
      --temp <N>          temperature（默认 0）
      --fmt <text|json>   输出格式（默认 text）
      --schema <JSON>     JSON Schema 字符串（优先于 --fmt）
      --no-cache [val]    兼容参数，忽略
      --base <URL>        Ollama 地址（默认 http://127.0.0.1:11434）
      --timeout <秒>      请求超时秒数（默认 300）
      --show-meta         向 stderr 输出耗时与 token 统计
  -h, --help              显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prompt)
      PROMPT="${2:-}"
      shift 2
      ;;
    -s|--sys)
      SYS="${2:-}"
      shift 2
      ;;
    -m|--model)
      MODEL="${2:-}"
      shift 2
      ;;
    --max-tok)
      MAX_TOK="${2:-700}"
      shift 2
      ;;
    --temp)
      TEMP="${2:-0}"
      shift 2
      ;;
    --fmt)
      FMT="${2:-text}"
      shift 2
      ;;
    --schema)
      SCHEMA="${2:-}"
      shift 2
      ;;
    --no-cache)
      if [[ $# -ge 2 && "${2:-}" != -* ]]; then
        NO_CACHE="$2"
        shift 2
      else
        shift 1
      fi
      ;;
    --base)
      BASE="${2:-http://127.0.0.1:11434}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="${2:-300}"
      shift 2
      ;;
    --show-meta)
      SHOW_META=1
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

if [[ -z "$PROMPT" ]]; then
  echo "!! 缺少必填参数：--prompt" >&2
  exit 1
fi

if [[ "$FMT" != "text" && "$FMT" != "json" ]]; then
  echo "!! --fmt 仅支持 text 或 json，当前：$FMT" >&2
  exit 1
fi

if [[ -z "$MODEL" ]]; then
  MODEL="${AMEM_MODEL:-qwen3-4b:q4}"
fi

find_python() {
  local cand
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
      if "$cand" -c "import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    fi
  done
  return 1
}

PY_BIN=""
if PY_BIN="$(find_python)"; then
  :
elif command -v jq >/dev/null 2>&1; then
  PY_BIN=""
else
  echo "!! 需要 python3/python 或 jq 来构造和解析 JSON" >&2
  exit 2
fi

build_body() {
  if [[ -n "$PY_BIN" ]]; then
    AMEM_P="$PROMPT" AMEM_S="$SYS" AMEM_M="$MODEL" \
    AMEM_MT="$MAX_TOK" AMEM_T="$TEMP" AMEM_F="$FMT" AMEM_SC="$SCHEMA" \
    "$PY_BIN" -c '
import json, os, sys
body = {
    "model": os.environ["AMEM_M"],
    "prompt": os.environ["AMEM_P"],
    "stream": False,
    "options": {
        "temperature": float(os.environ["AMEM_T"]),
        "num_predict": int(os.environ["AMEM_MT"]),
    },
}
sys_txt = os.environ.get("AMEM_S", "")
if sys_txt:
    body["system"] = sys_txt
schema_txt = os.environ.get("AMEM_SC", "")
fmt = os.environ.get("AMEM_F", "text")
if schema_txt:
    body["format"] = json.loads(schema_txt)
elif fmt == "json":
    body["format"] = "json"
sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
'
  else
    local fmt_arg="null"
    if [[ -n "$SCHEMA" ]]; then
      jq -nc \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --arg sys "$SYS" \
        --argjson temp "$TEMP" \
        --argjson max_tok "$MAX_TOK" \
        --argjson schema "$SCHEMA" \
        '({model:$model, prompt:$prompt, stream:false, options:{temperature:$temp, num_predict:$max_tok}}
          + (if $sys != "" then {system:$sys} else {} end)
          + {format:$schema})'
    elif [[ "$FMT" == "json" ]]; then
      jq -nc \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --arg sys "$SYS" \
        --argjson temp "$TEMP" \
        --argjson max_tok "$MAX_TOK" \
        '({model:$model, prompt:$prompt, stream:false, options:{temperature:$temp, num_predict:$max_tok}}
          + (if $sys != "" then {system:$sys} else {} end)
          + {format:"json"})'
    else
      jq -nc \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --arg sys "$SYS" \
        --argjson temp "$TEMP" \
        --argjson max_tok "$MAX_TOK" \
        '({model:$model, prompt:$prompt, stream:false, options:{temperature:$temp, num_predict:$max_tok}}
          + (if $sys != "" then {system:$sys} else {} end))'
    fi
  fi
}

BODY_JSON="$(build_body)"

TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT

HTTP_CODE=""
CURL_ERR=""
if ! HTTP_CODE="$(printf '%s' "$BODY_JSON" | curl -sS --max-time "$TIMEOUT_SEC" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -o "$TMP_RESP" -w '%{http_code}' \
  -X POST "${BASE%/}/api/generate" --data-binary @- 2>&1)"; then
  echo "!! Ollama 请求失败（$BASE）：$HTTP_CODE"
  echo "   先确认服务：ollama serve    或    curl -s ${BASE%/}/api/version"
  exit 2
fi

if [[ ! "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
  ERR_BODY="$(head -c 300 "$TMP_RESP" 2>/dev/null || true)"
  echo "!! Ollama 请求失败（$BASE）：HTTP $HTTP_CODE $ERR_BODY"
  echo "   先确认服务：ollama serve    或    curl -s ${BASE%/}/api/version"
  exit 2
fi

if [[ -n "$PY_BIN" ]]; then
  AMEM_RESP_FILE="$TMP_RESP" AMEM_MODEL_NAME="$MODEL" AMEM_SHOW_META="$SHOW_META" \
  "$PY_BIN" -c '
import json, os, sys
with open(os.environ["AMEM_RESP_FILE"], "r", encoding="utf-8") as f:
    data = json.load(f)
if "error" in data and data["error"]:
    sys.stderr.write("!! Ollama 返回错误：" + str(data["error"]) + "\n")
    sys.exit(2)
if os.environ.get("AMEM_SHOW_META") == "1":
    cnt = data.get("eval_count", 0) or 0
    dur = (data.get("eval_duration", 0) or 0) / 1e9
    sys.stderr.write("[{} | eval {} tok | {:.1f}s]\n".format(os.environ["AMEM_MODEL_NAME"], cnt, dur))
resp = str(data.get("response", "")).strip()
sys.stdout.write(resp + ("\n" if resp else ""))
'
else
  if [[ "$SHOW_META" -eq 1 ]]; then
    CNT="$(jq -r '.eval_count // 0' "$TMP_RESP")"
    DUR="$(jq -r '((.eval_duration // 0) / 1e9)' "$TMP_RESP")"
    printf '[%s | eval %s tok | %.1fs]\n' "$MODEL" "$CNT" "$DUR" >&2
  fi
  ERR_MSG="$(jq -r '.error // empty' "$TMP_RESP")"
  if [[ -n "$ERR_MSG" ]]; then
    echo "!! Ollama 返回错误：$ERR_MSG" >&2
    exit 2
  fi
  jq -r '.response // ""' "$TMP_RESP" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
fi
