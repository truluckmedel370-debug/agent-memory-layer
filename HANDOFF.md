# HANDOFF · Linux/macOS 移植交付说明

## 交付清单

新增 `linux/` 目录，包含以下 5 个可执行脚本（均为 LF 换行）：

| 文件 | 对应原件 | 职责 |
|---|---|---|
| `linux/ai.sh` | `ai.ps1` | Ollama `/api/generate` 接口层，支持 `--schema`（完整 JSON Schema 传给 `format`）、`--fmt json`、`--sys`、`--model`、`--max-tok`、`--temp`、`--base`、`--timeout`、`--show-meta` |
| `linux/recall.sh` | `recall.ps1` | 读路径快照：按 `MEMORY.md` → `PENDING.md` → `INBOX.md`（非空才输出内容，标题带待合并条数）→ `LOG.md` 尾部 N 行输出，末行自报字符数、token 估算（`N/1.6`–`N/1.2`）及 90 行预算告警 |
| `linux/memo.sh` | `memo.ps1` | 手工读写检索：支持子命令风格（`show` / `search` / `log` / `mem` / `pending`）与参数风格（`--kind` / `--text` / `--search` / `--show`） |
| `linux/remember.sh` | `remember.ps1` | 写路径：`.digest-state.json` 游标、`LOG.md` 分段解析、`[事实]`/`[fact]` 提取与 `--all`、分批调用 `ai.sh`（传完整 JSON Schema）、`[...]`/`{...}` 容错解析、硬编码分类分值（身份=3/环境=2/口径=2/坑=2/其它=1）、bigram 相似度去重（`max(jaccard, coverage*0.9) >= 0.55`）、写 `INBOX.md`、`--prune` 归档到 `ARCHIVE.md` |
| `linux/selftest.sh` | — | 零依赖自测脚本（仅需 `bash` + `curl` + `python3/python`），使用本地临时 mock Ollama HTTP 服务与 `examples/` 模板在沙箱目录中完成全流程校验 |

## 目录定位约定

脚本按以下优先级确定记忆库根目录：
1. 环境变量 `AMEM_ROOT`（若已设置）
2. 脚本所在目录（若存在 `MEMORY.md` 或 `LOG.md`）
3. 脚本上级目录（即仓库根目录，适配直接运行 `./linux/recall.sh`）
4. 当前工作目录 `$PWD`

## 自测结果

在本机 Windows Git Bash（`C:\Program Files\Git\bin\bash.exe`，GNU bash 5.3.15 + Python 3.10.6 + curl）下运行 `./linux/selftest.sh`：

- 结果：**PASS=40, FAIL=0**（exit code 0）
- 覆盖点：`recall.sh` 输出顺序/计数/预算告警、`memo.sh` 五类子命令、`ai.sh` 请求体与 JSON Schema 校验、`remember.sh` 分段解析/过滤/打分/bigram 去重/`--dry-run`/游标推进/单对象容错/失败不推进游标/`--prune` 归档与 `--reset --all`。

## 后续人工验收建议（Linux / macOS / 本机）

```bash
cd linux
chmod +x *.sh
./selftest.sh
```

若连接真实本地 Ollama：

```bash
./linux/remember.sh --dry-run
./linux/recall.sh
```
