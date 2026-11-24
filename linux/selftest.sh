#!/usr/bin/env bash
# selftest.sh —— agent-memory-layer Linux/macOS 零依赖自测脚本
#
# 依赖需求：
#   - bash（Linux / macOS / Windows Git Bash 或 WSL）
#   - curl
#   - python3（或 python 3.x，用于临时 mock Ollama HTTP 服务与 JSON/UTF-8 校验）
# 无需安装 jq、无需联网、无需启动真实 Ollama 服务。

set -euo pipefail

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
EXAMPLES_DIR="$REPO_ROOT/examples"

for f in ai.sh recall.sh memo.sh remember.sh; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "FAIL: 缺少 $SCRIPT_DIR/$f"
    exit 1
  fi
done

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

PY_BIN="$(find_python)" || { echo "FAIL: 需要 python3/python"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: 需要 curl"; exit 1; }

SANDBOX="$(mktemp -d)"
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

PASS=0
FAIL=0
assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (未找到: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "  FAIL: $desc (不应包含: $needle)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local got="$1" expected="$2" desc="$3"
  if [[ "$got" == "$expected" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (期望: '$expected', 实际: '$got')"
    FAIL=$((FAIL + 1))
  fi
}

init_sandbox() {
  rm -f "$SANDBOX"/*.md "$SANDBOX/.digest-state.json"
  cp "$EXAMPLES_DIR/MEMORY.template.md" "$SANDBOX/MEMORY.md"
  cp "$EXAMPLES_DIR/PENDING.template.md" "$SANDBOX/PENDING.md"
  cp "$EXAMPLES_DIR/INBOX.template.md" "$SANDBOX/INBOX.md"
  cp "$EXAMPLES_DIR/LOG.template.md" "$SANDBOX/LOG.md"
  cp "$EXAMPLES_DIR/ARCHIVE.template.md" "$SANDBOX/ARCHIVE.md"
}

export AMEM_ROOT="$SANDBOX"

echo "=== 1. 测试 recall.sh ==="
init_sandbox
OUT_RECALL="$(bash "$SCRIPT_DIR/recall.sh")"
assert_contains "$OUT_RECALL" "===== MEMORY.md（26 行）=====" "recall 输出 MEMORY.md 行数"
assert_contains "$OUT_RECALL" "===== PENDING.md =====" "recall 输出 PENDING.md"
assert_contains "$OUT_RECALL" "===== INBOX.md（待合并 0 条）=====" "recall 空 INBOX 计数为 0"
assert_contains "$OUT_RECALL" "（空）" "recall 空 INBOX 显示（空）"
assert_contains "$OUT_RECALL" "===== LOG.md 最新 15 行 =====" "recall 默认 LOG 15 行"
assert_contains "$OUT_RECALL" "MEMORY 预算 90 行，现在 26 行]" "recall 末行预算自报"
assert_not_contains "$OUT_RECALL" "!! MEMORY 超预算" "未超 90 行不告警"

# 测试 INBOX 非空 + 超 90 行告警 + -l 2
printf '\n- [ ] (环境|2) 测试待合并条目  ← 2026-01-01 12:00\n' >> "$SANDBOX/INBOX.md"
for i in $(seq 1 70); do
  echo "- 第 $i 条长期记忆" >> "$SANDBOX/MEMORY.md"
done
OUT_OVER="$(bash "$SCRIPT_DIR/recall.sh" -l 2)"
assert_contains "$OUT_OVER" "===== INBOX.md（待合并 1 条）=====" "recall 非空 INBOX 计数为 1"
assert_contains "$OUT_OVER" "测试待合并条目" "recall 非空 INBOX 输出内容"
assert_contains "$OUT_OVER" "===== LOG.md 最新 2 行 =====" "recall -l 2 生效"
assert_contains "$OUT_OVER" "!! MEMORY 超预算：先把重复条目合并，再写新的" "超 90 行触发告警"

echo "=== 2. 测试 memo.sh ==="
init_sandbox
OUT_SHOW="$(bash "$SCRIPT_DIR/memo.sh" show)"
assert_contains "$OUT_SHOW" "===== MEMORY.md =====" "memo show 输出 MEMORY"
assert_contains "$OUT_SHOW" "===== PENDING.md =====" "memo show 输出 PENDING"

OUT_LOG="$(bash "$SCRIPT_DIR/memo.sh" log "[事实] 测试新日志插入到顶部")"
assert_contains "$OUT_LOG" "已写入 LOG.md 顶部：" "memo log 返回提示"
FIRST_HEAD="$(grep -m 1 '^## ' "$SANDBOX/LOG.md")"
assert_not_contains "$FIRST_HEAD" "2026-01-01 12:00" "memo log 新条目插在旧条目之上"

OUT_MEM="$(bash "$SCRIPT_DIR/memo.sh" mem "Python 路径在 /usr/bin/python3")"
assert_contains "$OUT_MEM" "已追加到 MEMORY.md 尾部" "memo mem 返回提示"
assert_contains "$(cat "$SANDBOX/MEMORY.md")" "Python 路径在 /usr/bin/python3" "memo mem 写入内容"

OUT_PEND="$(bash "$SCRIPT_DIR/memo.sh" pending "- [ ] 验证自测脚本")"
assert_contains "$OUT_PEND" "已追加到 PENDING.md" "memo pending 返回提示"
assert_contains "$(cat "$SANDBOX/PENDING.md")" "验证自测脚本" "memo pending 写入内容"

OUT_SEARCH="$(bash "$SCRIPT_DIR/memo.sh" search "Ollama")"
assert_contains "$OUT_SEARCH" "LOG.md:" "memo search 命中 LOG.md"

echo "=== 3. 启动 Mock Ollama 服务测试 ai.sh 与 remember.sh ==="
PORT_FILE="$SANDBOX/mock_port"
REQ_LOG="$SANDBOX/mock_requests.jsonl"
MOCK_MODE_FILE="$SANDBOX/mock_mode"
echo "normal" > "$MOCK_MODE_FILE"

"$PY_BIN" - "$PORT_FILE" "$REQ_LOG" "$MOCK_MODE_FILE" <<'PYEOF' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, req_log, mode_file = sys.argv[1:4]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def do_GET(self):
        if self.path == "/api/version":
            body = json.dumps({"version": "0.5.0-mock"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def do_POST(self):
        if self.path != "/api/generate":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8")
        data = json.loads(raw)
        with open(req_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
        with open(mode_file, "r", encoding="utf-8") as f:
            mode = f.read().strip()
        if mode == "single_obj":
            resp_str = json.dumps({"i": 1, "kind": "口径"}, ensure_ascii=False)
        elif mode == "bad_json":
            resp_str = "完全不是JSON输出"
        else:
            # 解析 prompt 里的编号句，按关键词返回分类
            items = []
            for line in data.get("prompt", "").splitlines():
                if line.startswith("[") and "]" in line:
                    idx = int(line[1:line.index("]")])
                    txt = line[line.index("]")+1:].strip()
                    if "称呼" in txt or "偏好" in txt:
                        k = "身份"
                    elif "Ollama" in txt or "端口" in txt or "路径" in txt:
                        k = "环境"
                    elif "规范" in txt or "不要" in txt:
                        k = "口径"
                    elif "踩坑" in txt or "报错" in txt:
                        k = "坑"
                    else:
                        k = "项目"
                    items.append({"i": idx, "kind": k})
            resp_str = json.dumps(items, ensure_ascii=False)
        out = json.dumps({
            "response": resp_str,
            "eval_count": 42,
            "eval_duration": 500000000,
        }, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)

srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
MOCK_PID=$!

for _ in $(seq 1 30); do
  if [[ -s "$PORT_FILE" ]]; then break; fi
  sleep 0.1
done
MOCK_PORT="$(cat "$PORT_FILE")"
export AMEM_OLLAMA_BASE="http://127.0.0.1:$MOCK_PORT"

# 3a. 测试 ai.sh Schema 与请求体
SCHEMA='{"type":"array","items":{"type":"object","properties":{"i":{"type":"integer"},"kind":{"type":"string","enum":["身份","环境","口径","坑","项目"]}},"required":["i","kind"]}}'
AI_OUT="$(bash "$SCRIPT_DIR/ai.sh" --prompt "[1] 用户偏好简洁输出" --sys "测试系统提示" --model "test-model" --max-tok 700 --temp 0 --fmt json --schema "$SCHEMA" --no-cache yes)"
assert_contains "$AI_OUT" '"kind": "身份"' "ai.sh 返回 mock 响应"

"$PY_BIN" - "$REQ_LOG" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    req = json.loads(f.readline())
assert req["model"] == "test-model", req
assert req["stream"] is False, req
assert req["options"] == {"temperature": 0.0, "num_predict": 700}, req
assert req["system"] == "测试系统提示", req
fmt = req["format"]
assert fmt["type"] == "array", fmt
assert fmt["items"]["properties"]["i"]["type"] == "integer", fmt
assert fmt["items"]["properties"]["kind"]["enum"] == ["身份", "环境", "口径", "坑", "项目"], fmt
PYEOF
echo "  PASS: ai.sh 请求体与 JSON Schema 校验通过"
PASS=$((PASS + 1))

# 3b. 测试 remember.sh 解析、打分、去重、dry-run、写 INBOX、游标推进
init_sandbox
cat > "$SANDBOX/LOG.md" <<'EOF'
# LOG · 流水（新条目在最上）

> 每条 bullet 标性质：`[事实]` 值得长期留 / `[动作]` 只是一次动作。

## 2026-11-20 10:00

- [事实] 主人称呼为老板，偏好简洁直接汇报
- [fact] 踩坑：Windows 下 python3 可能是商店占位符
- [事实] 短句
- [动作] 跑了一次全量构建测试
- 无标记的一句话也应该超过八个字

## 2026-01-01 12:00

- [事实] 这台机器的 Ollama 监听 127.0.0.1:11434，模型装在 D 盘
- [事实] 这台机器的 Ollama 监听 127.0.0.1:11434，模型装在 D 盘上
- [事实] 本次临时整理一下项目进度说明
EOF

# dry-run 不写文件
OUT_DRY="$(bash "$SCRIPT_DIR/remember.sh" --dry-run --batch-size 2)"
assert_contains "$OUT_DRY" "LOG 2 条，已处理 0，新增待整理 2" "dry-run 识别 2 段未处理"
assert_contains "$OUT_DRY" "取到 [事实] 原句 5 条" "过滤短句/动作/无标记，保留 5 条 [事实]/[fact]"
assert_contains "$OUT_DRY" "~ 本轮重复，跳过：" "bigram 机械去重生效"
assert_contains "$OUT_DRY" "[DryRun] 将写入 INBOX.md：" "dry-run 输出计划写入"
if [[ -f "$SANDBOX/.digest-state.json" ]]; then
  echo "  FAIL: dry-run 不应创建 .digest-state.json"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: dry-run 未写入 .digest-state.json"
  PASS=$((PASS + 1))
fi

# 真实运行
OUT_RUN="$(bash "$SCRIPT_DIR/remember.sh" --batch-size 2 --model "qwen3-4b:q4")"
assert_contains "$OUT_RUN" "写入 INBOX.md 3 条待合并" "正常写入 3 条（身份3/坑2/环境2，项目1被min-score=2过滤，重复1条被去重）"
assert_contains "$OUT_RUN" "已处理 2/2 条（游标推进到第 2 条）" "游标推进到 2"
assert_contains "$(cat "$SANDBOX/INBOX.md")" "(身份|3) 主人称呼为老板，偏好简洁直接汇报" "INBOX 包含身份|3"
assert_contains "$(cat "$SANDBOX/INBOX.md")" "(坑|2) 踩坑：Windows 下 python3 可能是商店占位符" "INBOX 包含坑|2"
assert_not_contains "$(cat "$SANDBOX/INBOX.md")" "项目进度说明" "score=1 的项目类未入 INBOX"

# 再次运行应无新流水
OUT_AGAIN="$(bash "$SCRIPT_DIR/remember.sh")"
assert_contains "$OUT_AGAIN" "没有新流水需要整理。" "游标生效，二次运行无新流水"

# 3c. 测试单对象容错 & 失败不推进游标
bash "$SCRIPT_DIR/memo.sh" log "[事实] 口径：所有脚本必须支持 --help 规范" >/dev/null
echo "single_obj" > "$MOCK_MODE_FILE"
OUT_SINGLE="$(bash "$SCRIPT_DIR/remember.sh")"
assert_contains "$OUT_SINGLE" "写入 INBOX.md 1 条待合并" "单对象响应 {...} 容错包成数组成功"

bash "$SCRIPT_DIR/memo.sh" log "[事实] 环境：新增一条会失败的测试记录" >/dev/null
echo "bad_json" > "$MOCK_MODE_FILE"
OUT_FAIL="$(bash "$SCRIPT_DIR/remember.sh")"
assert_contains "$OUT_FAIL" "!! 没解析出 JSON，跳过这批" "非法响应报跳过"
assert_contains "$OUT_FAIL" "!! 有批次没跑成功，游标保持不动" "失败时游标不动"

# 验证游标确实停在 3 而不是 4
PROCESSED_VAL="$(cat "$SANDBOX/.digest-state.json" | "$PY_BIN" -c "import json,sys; print(json.load(sys.stdin)['processed'])")"
assert_eq "$PROCESSED_VAL" "3" "失败后 processed 仍为 3"

# 3d. 测试 --prune 归档旧条目 + --all + --reset
echo "normal" > "$MOCK_MODE_FILE"
OUT_PRUNE="$(bash "$SCRIPT_DIR/remember.sh" --prune --days-keep-log 60 --reset --all)"
assert_contains "$OUT_PRUNE" "归档 1 条 → ARCHIVE.md（>60 天）" "--prune 归档超过 60 天的条目"
assert_contains "$(cat "$SANDBOX/ARCHIVE.md")" "2026-01-01 12:00" "ARCHIVE.md 包含归档条目"
assert_not_contains "$(cat "$SANDBOX/LOG.md")" "2026-01-01 12:00" "LOG.md 已移除归档条目"

echo ""
echo "==============================="
echo "自测完成：PASS=$PASS, FAIL=$FAIL"
echo "==============================="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
