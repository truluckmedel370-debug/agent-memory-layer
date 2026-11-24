#!/usr/bin/env bash
# remember.sh —— 自动记忆整理器 v2（本地 Ollama 只负责分类/打分，字面内容不过模型）
#
# 用法：
#   ./remember.sh                         # 增量整理
#   ./remember.sh --prune                 # 归档老化流水 + 体检
#   ./remember.sh --dry-run               # 只看结果，不写文件
#   ./remember.sh --model abl-8b:q4       # 换模型
#   ./remember.sh --reset                 # 重头处理全部 LOG（慎用）

set -euo pipefail

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # Windows 上 python 默认按 cp936 输出，会把中文 JSON 变成 GBK 字节
DRY_RUN=0
PRUNE=0
RESET=0
ALL=0
NO_AUTO_START=0
DAYS_KEEP_LOG=60
MODEL="${AMEM_MODEL:-qwen3-4b:q4}"
MIN_SCORE=2
BATCH_SIZE=10
BASE="${AMEM_OLLAMA_BASE:-http://127.0.0.1:11434}"

usage() {
  cat <<'EOF'
用法：remember.sh [选项]

选项：
      --dry-run             只输出计划写入的内容，不写文件、不推进游标
      --prune               归档超过保留期的 LOG 条目到 ARCHIVE.md 并检查 MEMORY 行数
      --reset               忽略游标，从头处理全部 LOG
      --all                 连同 [动作]/[进度] 与无标记 bullet 一并送分类
      --no-auto-start       Ollama 未运行时不尝试自动拉起
      --model <模型>        指定 Ollama 模型（默认 qwen3-4b:q4）
      --min-score <N>       入库最低分（默认 2）
      --batch-size <N>      每批送模型的句数（默认 10）
      --days-keep-log <N>   LOG 保留天数（默认 60）
      --base <URL>          Ollama 地址（默认 http://127.0.0.1:11434）
  -h, --help                显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift 1
      ;;
    --prune)
      PRUNE=1
      shift 1
      ;;
    --reset)
      RESET=1
      shift 1
      ;;
    --all)
      ALL=1
      shift 1
      ;;
    --no-auto-start)
      NO_AUTO_START=1
      shift 1
      ;;
    --model)
      MODEL="${2:-qwen3-4b:q4}"
      shift 2
      ;;
    --min-score)
      MIN_SCORE="${2:-2}"
      shift 2
      ;;
    --batch-size)
      BATCH_SIZE="${2:-10}"
      shift 2
      ;;
    --days-keep-log)
      DAYS_KEEP_LOG="${2:-60}"
      shift 2
      ;;
    --base)
      BASE="${2:-http://127.0.0.1:11434}"
      shift 2
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

AI_SH="${AMEM_AI_SH:-$SCRIPT_DIR/ai.sh}"
if [[ ! -f "$AI_SH" ]]; then
  echo "!! 找不到 $AI_SH"
  exit 2
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
if ! PY_BIN="$(find_python)"; then
  echo "!! remember.sh 需要 python3/python（用于 UTF-8 分段解析、bigram 去重与 JSON Schema 处理）" >&2
  exit 2
fi

# ---------- 0. 前置：Ollama 不在就自己拉起来 ----------
OLLAMA_UP=0
if curl -sS --max-time 4 "${BASE%/}/api/version" >/dev/null 2>&1; then
  OLLAMA_UP=1
fi

if [[ "$OLLAMA_UP" -eq 0 && "$NO_AUTO_START" -eq 0 ]]; then
  if command -v ollama >/dev/null 2>&1; then
    echo "Ollama 未运行，拉起：ollama serve"
    nohup ollama serve >/dev/null 2>&1 &
    sleep 8
    if curl -sS --max-time 6 "${BASE%/}/api/version" >/dev/null 2>&1; then
      OLLAMA_UP=1
    fi
  fi
fi

if [[ "$OLLAMA_UP" -eq 0 ]]; then
  echo "!! Ollama 起不来（${BASE} 无响应），本次不整理，游标不动，下次再来"
  exit 2
fi

# ---------- 0b. 目录与文件 + 1~8 主流程 ----------
export AMEM_ROOT_DIR="$ROOT"
export AMEM_AI_SH_PATH="$AI_SH"
export AMEM_BASE_URL="${BASE%/}"
export AMEM_DRY_RUN="$DRY_RUN"
export AMEM_PRUNE="$PRUNE"
export AMEM_RESET="$RESET"
export AMEM_ALL="$ALL"
export AMEM_DAYS_KEEP_LOG="$DAYS_KEEP_LOG"
export AMEM_MODEL_NAME="$MODEL"
export AMEM_MIN_SCORE="$MIN_SCORE"
export AMEM_BATCH_SIZE="$BATCH_SIZE"

"$PY_BIN" - <<'PYEOF'
import datetime
import json
import math
import os
import re
import subprocess
import sys

root = os.environ["AMEM_ROOT_DIR"]
ai_sh = os.environ["AMEM_AI_SH_PATH"]
base_url = os.environ["AMEM_BASE_URL"]
dry_run = os.environ["AMEM_DRY_RUN"] == "1"
prune = os.environ["AMEM_PRUNE"] == "1"
reset = os.environ["AMEM_RESET"] == "1"
include_all = os.environ["AMEM_ALL"] == "1"
days_keep_log = int(os.environ["AMEM_DAYS_KEEP_LOG"])
model = os.environ["AMEM_MODEL_NAME"]
min_score = int(os.environ["AMEM_MIN_SCORE"])
batch_size = max(1, int(os.environ["AMEM_BATCH_SIZE"]))

log_p = os.path.join(root, "LOG.md")
mem_p = os.path.join(root, "MEMORY.md")
inbox_p = os.path.join(root, "INBOX.md")
arch_p = os.path.join(root, "ARCHIVE.md")
state_p = os.path.join(root, ".digest-state.json")


def read_all(p):
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8") as f:
            return f.read().replace("\r\n", "\n").replace("\r", "\n")
    return ""


def write_all(p, s):
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


# ---------- 0b. 初始化 INBOX / ARCHIVE ----------
if not os.path.exists(inbox_p):
    write_all(
        inbox_p,
        "# INBOX · 待合并的长期事实候选\n\n"
        "> 由 remember.sh 自动产出（原句直取，不经模型改写）。\n"
        "> deepseek 开工时逐条审核：并进 `MEMORY.md` 对应小节后删除该行。\n\n",
    )

if not os.path.exists(arch_p):
    write_all(
        arch_p,
        f"# ARCHIVE · 归档\n\n> 超过 {days_keep_log} 天的流水。只读不删，需要时 grep。\n\n",
    )

# ---------- 1. 状态与 LOG ----------
state = {"lastStamp": "0000-00-00 00:00"}
if os.path.exists(state_p) and not reset:
    try:
        loaded = json.loads(read_all(state_p))
        if isinstance(loaded, dict):
            state = loaded
    except Exception:
        pass

def get_entries(text):
    out = []
    cur = None
    for ln in text.split("\n"):
        m = re.match(r"^##\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})", ln)
        if m:
            if cur is not None:
                out.append(cur)
            cur = {"stamp": m.group(1), "head": ln, "body": []}
        elif cur is not None:
            cur["body"].append(ln)
    if cur is not None:
        out.append(cur)
    return out


log_text = read_all(log_p)
entries = get_entries(log_text)

if "processed" in state:
    processed = int(state["processed"])
elif state.get("lastStamp"):
    ls = str(state["lastStamp"])
    processed = sum(1 for e in entries if e["stamp"] <= ls)
else:
    processed = 0

if reset:
    processed = 0
processed = min(processed, len(entries))

new_count = max(0, len(entries) - processed)
new_entries = entries[:new_count] if new_count > 0 else []
print(f"LOG {len(entries)} 条，已处理 {processed}，新增待整理 {len(new_entries)}")

# ---------- 2. 老化归档 ----------
if prune:
    cut = datetime.datetime.now() - datetime.timedelta(days=days_keep_log)
    old_entries = []
    keep_entries = []
    for e in entries:
        dt = datetime.datetime.strptime(e["stamp"], "%Y-%m-%d %H:%M")
        if dt < cut:
            old_entries.append(e)
        else:
            keep_entries.append(e)

    if old_entries:
        block = "\n\n".join(
            e["head"] + "\n" + "\n".join(e["body"]).rstrip() for e in old_entries
        )
        if not dry_run:
            write_all(arch_p, read_all(arch_p) + "\n" + block + "\n")
            head_txt = (
                "# LOG · 流水（新条目在最上）\n\n"
                "> 每条 bullet 标性质：`[事实]` 值得长期留 / `[动作]` 只是一次动作。\n"
                "> 只追加，不改旧条。\n\n"
            )
            keep_sorted = sorted(keep_entries, key=lambda x: x["stamp"], reverse=True)
            body_txt = "\n\n".join(
                e["head"] + "\n" + "\n".join(e["body"]).rstrip() for e in keep_sorted
            )
            write_all(log_p, head_txt + body_txt + "\n")
            entries = get_entries(read_all(log_p))
            processed = min(processed, len(entries))
            new_count = max(0, len(entries) - processed)
            new_entries = entries[:new_count] if new_count > 0 else []
        print(f"归档 {len(old_entries)} 条 → ARCHIVE.md（>{days_keep_log} 天）")
    else:
        print(f"无需归档（没有超过 {days_keep_log} 天的条目）")

    mem_lines = len(read_all(mem_p).split("\n"))
    if mem_lines > 120:
        print(f"!! MEMORY.md {mem_lines} 行，超预算 120，该合并压缩")
    else:
        print(f"MEMORY.md {mem_lines} 行（预算 120）")

if len(new_entries) == 0:
    print("没有新流水需要整理。")
    sys.exit(0)

# ---------- 3. 从新增流水里取「[事实]」原句 ----------
items = []
for e in new_entries:
    for ln in e["body"]:
        t = ln.strip()
        m_b = re.match(r"^-+\s*(\S.*)$", t)
        if not m_b:
            continue
        t = m_b.group(1).strip()
        if t.startswith("#"):
            continue
        m_fact = re.match(r"^\[(事实|fact)\]\s*(.+)$", t)
        m_act = re.match(r"^\[(动作|进度|action)\]\s*(.+)$", t)
        if m_fact:
            t = m_fact.group(2).strip()
        elif m_act:
            if not include_all:
                continue
            t = m_act.group(2).strip()
        elif not include_all:
            continue
        if len(t) < 8:
            continue
        items.append({"text": t, "stamp": e["stamp"]})

print(f"取到 [事实] 原句 {len(items)} 条")
if len(items) == 0:
    print("没有 [事实] 条目要整理（[动作] 不入库）。")
    if not dry_run:
        now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.datetime.now(datetime.timezone.utc).microsecond // 1000:03d}Z"
        out = {
            "processed": len(entries),
            "lastStamp": "",
            "updatedAt": now_utc,
            "model": model,
        }
        write_all(state_p, json.dumps(out, ensure_ascii=False, indent=2) + "\n")
        print(f"已处理 {len(entries)} 条（无事实可提）")
    sys.exit(0)

# ---------- 4. 已有记忆 + bigram 去重 ----------
existing = []
for l in read_all(mem_p).split("\n"):
    if re.match(r"^\s*[-*]\s+\S", l) and len(l) > 12:
        existing.append(l.strip())
for l in read_all(inbox_p).split("\n"):
    if re.match(r"^\s*-\s+\[", l) and len(l) > 12:
        cleaned = re.sub(r"^- \[.\]\s*\([^)]*\)\s*", "", l.strip())
        existing.append(cleaned)

existing_brief = "\n".join(
    "- " + re.sub(r"^- \[.\]\s*\([^)]*\)\s*", "", x) for x in existing[:50]
)
if not existing_brief:
    existing_brief = "（暂无）"

STRIP_RE = re.compile(r'[\s`*_\[\]()（）「」"\'’‘，。、：；！？,.:;!?|—\-~→]+')


def get_bigrams(s):
    s = STRIP_RE.sub("", s)
    if len(s) < 2:
        return {s} if len(s) == 1 else set()
    return {s[i : i + 2] for i in range(len(s) - 1)}


def similarity(a, b):
    A = get_bigrams(a)
    B = get_bigrams(b)
    if not A or not B:
        return 0.0
    inter = len(A & B)
    jac = inter / (len(A) + len(B) - inter)
    cov = inter / min(len(A), len(B))
    return round(max(jac, cov * 0.9), 3)


sys_prompt = """你是记忆分类器。给你一批「工作流水原句」（带编号），逐句判类，不要改写句子。

类别只能选一个：
- 身份 = 主人的身份、称谓、长期偏好、明确禁项
- 环境 = 这台机器的路径、软件、配置、账号、目录结构
- 口径 = 做事的方法与标准（以后该怎么做、不要怎么做）
- 坑 = 踩过的错、会反复出问题的地方
- 项目 = 具体某件事的进度、某次动作、某个产出（做完就过期）

判断诀窍：这句话是「描述了以后都要遵守／会反复用到的事实」，还是「记录某次做了什么」。
后者一律 项目。拿不准也选 项目（宁可漏记，不要污染记忆）。

只输出 JSON 数组：[{"i":1,"kind":"口径"},{"i":2,"kind":"项目"}]
每个编号必须出现且只出现一次。不要输出解释，不要输出其他文字。"""
sys_prompt = sys_prompt + "\n【已记录的长期记忆，仅供判断参考，不要评论】\n" + existing_brief

SCORE_MAP = {
    "身份": 3,
    "环境": 2,
    "口径": 2,
    "坑": 2,
}


def get_score(kind):
    return SCORE_MAP.get(kind.strip(), 1)


# ---------- 5. 分批问模型 ----------
schema = '{"type":"array","items":{"type":"object","properties":{"i":{"type":"integer"},"kind":{"type":"string","enum":["身份","环境","口径","坑","项目"]}},"required":["i","kind"]}}'
labels = {}
failed = False
batches = math.ceil(len(items) / batch_size)

for b in range(batches):
    start = b * batch_size
    end = min(start + batch_size, len(items))
    chunk = items[start:end]
    numbered = [f"[{start + i + 1}] {it['text']}" for i, it in enumerate(chunk)]
    prompt = "\n".join(numbered) + "\n\n输出 JSON："
    print(f"  批次 {b + 1}/{batches}：{len(chunk)} 句 → {model}")

    try:
        proc = subprocess.run(
            [
                "bash",
                ai_sh,
                "--prompt", prompt,
                "--sys", sys_prompt,
                "--model", model,
                "--max-tok", "700",
                "--temp", "0",
                "--fmt", "json",
                "--schema", schema,
                "--no-cache", "yes",
                "--base", base_url,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
            print(f"  !! 模型调用失败：{err}")
            failed = True
            continue
        raw = proc.stdout or ""
    except Exception as ex:
        print(f"  !! 模型调用失败：{ex}")
        failed = True
        continue

    m_arr = re.search(r"\[[\s\S]*\]", raw)
    if m_arr:
        json_text = m_arr.group(0)
    else:
        m_obj = re.search(r"\{[\s\S]*\}", raw)
        if not m_obj:
            print("  !! 没解析出 JSON，跳过这批")
            failed = True
            continue
        json_text = "[" + m_obj.group(0) + "]"

    try:
        arr = json.loads(json_text)
        if isinstance(arr, dict):
            arr = [arr]
    except Exception:
        print("  !! JSON 非法，跳过这批")
        failed = True
        continue

    for it in arr:
        if not isinstance(it, dict) or "i" not in it or "kind" not in it:
            continue
        try:
            idx = int(it["i"])
        except Exception:
            continue
        if idx < 1 or idx > len(items):
            continue
        k = str(it["kind"])
        labels[idx] = {"kind": k, "score": get_score(k)}

# ---------- 6. 过滤 + 机械去重 ----------
picked = []
for i, it in enumerate(items):
    n = i + 1
    if n not in labels:
        print(f"  x 模型漏标，待人工看：{it['text']}")
        continue
    lb = labels[n]
    if lb["score"] < min_score:
        continue

    if any(similarity(it["text"], e) >= 0.55 for e in existing):
        print(f"  ~ 已覆盖，跳过：{it['text']}")
        continue

    if any(similarity(it["text"], p["text"]) >= 0.55 for p in picked):
        print(f"  ~ 本轮重复，跳过：{it['text']}")
        continue

    picked.append({
        "text": it["text"],
        "kind": lb["kind"],
        "score": lb["score"],
        "stamp": it["stamp"],
    })

# ---------- 7. 写 INBOX ----------
now_short = datetime.datetime.now().strftime("%m-%d %H:%M")
if not picked:
    print("本轮没有达标的新事实。")
else:
    add = "\n".join(
        f"- [ ] ({p['kind']}|{p['score']}) {p['text']}  ← {p['stamp']}"
        for p in picked
    )
    if dry_run:
        print("\n[DryRun] 将写入 INBOX.md：")
        print(add)
    else:
        inbox = read_all(inbox_p)
        if inbox and not inbox.endswith("\n"):
            inbox += "\n"
        write_all(inbox_p, inbox + f"\n<!-- 整理于 {now_short} -->\n" + add + "\n")
        print(f"\n写入 INBOX.md {len(picked)} 条待合并")

# ---------- 8. 推进游标 ----------
if failed:
    print("!! 有批次没跑成功，游标保持不动，下次自动重试这几句（本次已入队的不会重复，靠去重挡）")
elif not dry_run:
    newest = max((e["stamp"] for e in new_entries), default="")
    now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.datetime.now(datetime.timezone.utc).microsecond // 1000:03d}Z"
    out = {
        "processed": len(entries),
        "lastStamp": newest,
        "updatedAt": now_utc,
        "model": model,
    }
    write_all(state_p, json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print(f"已处理 {len(entries)}/{len(entries)} 条（游标推进到第 {len(entries)} 条）")
PYEOF
