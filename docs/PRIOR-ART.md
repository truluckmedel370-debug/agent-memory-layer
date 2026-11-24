# Agent 长期记忆 Prior Art 调研与差异化定位

> 调研时间：2026-11-24（GitHub star 数与 `pushed_at` 均为当日通过 GitHub REST API 实测查询结果）  
> 我方项目：`agent-memory-layer`（本地纯文本 Markdown + PowerShell / Bash 双实现 + Ollama 分类门控）

---

## 一、开源与主流方案对照表（共 12 个项目）

覆盖类别：(a) 纯文件/Markdown 方案、(b) 向量库/RAG 方案、(c) 托管服务、(d) 框架内置/平台级记忆。

| 项目 | 存储形态 | 谁写记忆文本（模型/人/规则） | 有无预算/淘汰机制 | 检索方式 | 依赖 | 平台 | 最近更新 | 与我方重叠 | 我方差异 |
|---|---|---|---|---|---|---|---|---|---|
| [supermemoryai/memoryrepo](https://github.com/supermemoryai/memoryrepo) (a) | Git 仓库 + `MEMORY.md` 入口 + 主题 Markdown + 双向链接 | **模型**（agent 读写 + 后台 dreaming agent 综合改写） | **有**（保持 `MEMORY.md` 简短，后台 agent 合并/裁剪矛盾与旧条目） | 每次加载 `MEMORY.md` + 主题文件遍历 | TypeScript、Git、Cloudflare Artifacts（设计背景） | 跨平台（TS/Git） | `2026-10-06` · 105 stars（精确） | 同为 `MEMORY.md` 入口 + 纯 Markdown + 预算/合并思路 | 我方模型**不写/不改写**任何文本，原句直取；不依赖 TS 或 Cloudflare |
| [agentconnect-md/agent-memory-template](https://github.com/agentconnect-md/agent-memory-template) (a) | 纯 Markdown（`MEMORY.md` 索引 + 主题文件）+ Git 同步 | **人 / 外部 coding agent**（模板本身无 LLM 写入管线） | **无**（无硬行数/淘汰脚本） | 文件直读 / 手工维护 | Python 3.9+、Bash、Git | macOS / Linux | `2026-10-16` · 0 stars（精确） | 同为纯 Markdown + `MEMORY.md` + 零数据库/零云依赖 | 我方有 Ollama 结构化分类门控、`INBOX` 审核流、90 行硬预算与 Windows 原生实现 |
| [basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory) (a) | 本地 Markdown（Obsidian 兼容）+ SQLite/Postgres 派生索引 | **人 + 模型**（人编辑 + agent 通过 MCP `write_note` 写入） | **无**（偏知识库累积，无硬行数淘汰） | MCP 工具 + SQLite 全文/语义图遍历 | Python、SQLite（或 Postgres）、MCP | 跨平台（Python） | `2026-11-24` · 4,697 stars（精确） | 同为本地 Markdown 作 source of truth、人类可读 | 我方不用 SQLite 与 MCP 服务，单条命令出快照，且模型不生成正文 |
| [akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory) (a/b) | Git-backed Markdown wiki（YAML frontmatter）+ 派生 SQLite 索引 | **规则 + 模型可选**（默认 zero-LLM 生命周期钩子 + 规则摘要） | **无**硬行数封顶（偏全量会话/决策归档） | 本地 embedding（`all-MiniLM`）+ SQLite FTS5 混合检索 + 图关系 | Rust 二进制、SQLite、本地 embedding 模型 | Linux / Windows（原生 PS 安装器） | `2026-11-23` · 16,338 stars（精确） | 同为 Markdown 真相源、零云依赖、兼顾 Windows 与 Linux | 我方无 SQLite 与 embedding 索引，不靠生命周期钩子自动抓会话，靠 `[事实]` 标 + 90 行预算控熵 |
| [zilliztech/memsearch](https://github.com/zilliztech/memsearch) (b) | Markdown 为 source of truth + Milvus / Milvus Lite 影子索引 | **人 / agent**（写入 `.md` 后由 SHA-256 去重切块建索引） | **渐进式披露**（摘要→章节→原文），无硬行数淘汰 | 稠密向量 + BM25 稀疏检索 + RRF 融合 | Python、Milvus / Milvus Lite、Embedding 模型 | 跨平台（Python） | `2026-11-24` · 2,934 stars（精确） | 同认 Markdown 为可审计真相源 | 我方不做向量库与混合检索，90 行以内直接全量快照读出 |
| [mem0ai/mem0](https://github.com/mem0ai/mem0) (b/c) | 向量库（Qdrant 等）+ 可选图数据库 / Mem0 托管云 | **模型**（LLM 自动从对话抽取、更新、合并 facts） | **有语义更新**（LLM 冲突覆盖/删除，无固定行数预算） | 向量相似度 + 元数据过滤 / 图检索 | Python/Node、向量库、LLM API + Embedding | 跨平台 / 云服务 | `2026-11-24` · 69,417 stars（精确） | 目标同为跨会话长期记忆持久化 | 我方拒绝模型自由抽取与向量检索，零云依赖、零文本改写 |
| [supermemoryai/supermemory](https://github.com/supermemoryai/supermemory) (c) | 托管 Memory API（Cloudflare 栈）或本地 Docker/二进制服务 | **模型**（自动切块、图谱抽取记忆） | **未验证**（API 侧有工作区/命名空间隔离，未见硬行数预算） | Memory API（向量 + 图谱混合检索） | Docker / 二进制服务 + LLM/Embedding 提供商 | 云托管 / Linux/macOS 自托管 | `2026-11-24` · 31,704 stars（精确） | 同关注跨会话记忆（同一团队另有 `memoryrepo`） | 我方为无服务端、无 API 的纯本地脚本 + 纯文本 |
| [getzep/zep](https://github.com/getzep/zep)（含 Zep Cloud）(c) | 托管企业级上下文平台（底层由 Graphiti 时序图谱驱动） | **模型**（从对话提取实体、事实与演化摘要） | **有时间失效机制**（新事实使旧边 `invalid_at`，保留历史时间线） | 向量 + 全文 + 时序图谱遍历混合检索 | Zep Cloud 服务 / 后端数据库与 LLM API | 云托管 / SDK | `2026-11-17` · 5,013 stars（精确） | 同重视「旧事实被新事实覆盖」的时序一致性 | 我方靠 `INBOX` 人工审核合并与 90 行预算解决冲突，零基础设施 |
| [getzep/graphiti](https://github.com/getzep/graphiti) (b/d) | 时序知识图谱（Neo4j / FalkorDB / Neptune） | **模型**（从 Episode 提取实体与带双时序边的三元组） | **有边失效机制**（`valid_at` / `invalid_at` 标废而非删除） | 向量 + 全文 + 图谱一并检索 | Python、Neo4j 等图数据库、LLM + Embedding | 跨平台（Python + 图库） | `2026-11-24` · 33,054 stars（精确） | 同强调事实随时间演化、避免新旧事实混用 | 我方面向单机个人/轻量 agent，无需图数据库与 LLM 实体抽取 |
| [letta-ai/letta](https://github.com/letta-ai/letta)（原 MemGPT）(d) | 分层内存：Core Memory（提示词块）+ Archival Memory（向量库） | **模型**（agent 自主调用 `core_memory_append/replace` 编辑） | **有**（Core Memory 块有硬字符上限，默认约 2,000 字符；Archival 无限） | Core 全量常驻上下文 + Archival 语义工具检索 | Python、后端数据库/向量库、LLM API | 跨平台（Python/Docker） | `2026-10-18` · 25,532 stars（精确） | Core Memory 常驻提示词 + 硬容量限制 + 归档分层思路高度相似 | 我方 `MEMORY.md` 由人/审核门控写、原句直取，不让模型直接改写 Core Memory |
| [langchain-ai/langmem](https://github.com/langchain-ai/langmem) (d) | LangGraph `BaseStore`（`InMemoryStore` / `AsyncPostgresStore` + 向量索引） | **模型**（后台或热路径 LLM 抽取语义/情景/程序性记忆） | **有合并/修剪**（工具支持更新与删除，无固定行数封顶） | 工具主动检索或后台自动注入（向量/关键词） | Python、LangGraph、Postgres/向量索引、LLM API | 跨平台（Python） | `2026-11-16` · 1,792 stars（精确） | 同区分后台整理与开工注入 | 我方完全脱离框架与数据库，纯文件即接口 |
| [topoteretes/cognee](https://github.com/topoteretes/cognee) (d) | 关系库 + 向量库（Qdrant/LanceDB）+ 图库（Neo4j/ArcadeDB/PG） | **模型**（ECL 管线 `cognify` 阶段由 LLM 抽取实体与关系） | **未验证**（偏知识图谱增量构建） | 向量定位入口节点 + 多跳图谱遍历 | Python、三类存储后端、LLM（支持 Ollama） | 跨平台（Python） | `2026-11-24` · 33,547 stars（精确） | 同支持本地小模型（Ollama）跑记忆管线 | 我方不建图谱与向量索引，也不让小模型生成实体/关系文本 |

> 补充参考评测与对比文档：
> - InfraNodus 对比矩阵：[Agent Memory Tools Compared](https://infranodus.com/docs/llm-memory-tools-comparison)（从存储形态、成本与人类可读性对比 Mem0、Zep/Graphiti、Letta、Cognee、Supermemory、LangMem 与本地纯文件方案）。
> - Reddit `r/AI_Agents` 实测讨论：[I ran 8 AI agent memory systems through 2176 tasks and a plain markdown wiki beat every product](https://www.reddit.com/r/AI_Agents/comments/1veeix3/)（2,176 项任务评测中，agent 维护的纯 Markdown wiki 综合得分 98.5，高于 Mitosis Cortex 96.9、gbrain 92.9、Mem0 92.3 等方案）。
>   **⚠ 该帖的具体分数未能独立复核**（2026-11-24 抓取返回 HTTP 403）。引用这组数字前请自行打开帖子核对；写入对外材料时建议只说"有社区评测把纯 Markdown wiki 作为强基线"，不背具体分数。

---

## 二、定位判断

### 1. "Markdown 当 agent 记忆"这个形态是否已被做透？

**结论：基础形态已经被做透，且已被社区基准测试验证为高性价比基线。**

证据如下：
- **纯 Markdown + Git 入口模式已高度撞车**：[supermemoryai/memoryrepo](https://github.com/supermemoryai/memoryrepo) 已经实现了「`MEMORY.md` 常驻入口 + 主题文件 + 每次写入一个 commit + 后台合并裁剪」；[agentconnect-md/agent-memory-template](https://github.com/agentconnect-md/agent-memory-template) 也已实现了「`MEMORY.md` 索引 + 纯 Markdown + 跨 agent Git 同步 + 零数据库」。
- **Markdown 作真相源 + 本地派生索引已是主流工程共识**：[akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory)（16,338 stars）、[basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory)（4,697 stars）、[zilliztech/memsearch](https://github.com/zilliztech/memsearch)（2,934 stars）均采用「Markdown 文件为人类可读的 single source of truth，底层索引可随时重建」。
- **实证评测已被公开打出声量**：Reddit [r/AI_Agents 评测贴](https://www.reddit.com/r/AI_Agents/comments/1veeix3/) 直接用 2,176 个任务证明了纯 Markdown wiki 方案能击败商业记忆产品；[InfraNodus 对比文档](https://infranodus.com/docs/llm-memory-tools-comparison) 也已将 `CLAUDE.md` / 本地纯文件归为常规基线类别。

因此，如果只讲「用 Markdown 做记忆、不用向量库/RAG」，很容易被当成上述成熟项目的极简版或重复造轮子。

---

### 2. 我方四条设计决定：哪些确实没人做过，哪些已有先例？

1. **「模型只对已标 `[事实]` 的句子做分类打分，不生成任何记忆文本（原句直取，幻觉面为零）」—— 确实未见相同先例（核心差异化）**
   - 检索证据：主流记忆系统（[mem0ai/mem0](https://github.com/mem0ai/mem0)、[langchain-ai/langmem](https://github.com/langchain-ai/langmem)、[topoteretes/cognee](https://github.com/topoteretes/cognee)、[getzep/graphiti](https://github.com/getzep/graphiti)、[supermemoryai/memoryrepo](https://github.com/supermemoryai/memoryrepo)）全部由 LLM 抽取、改写或总结记忆文本；不让模型写文本的方案（如 [agentconnect-md/agent-memory-template](https://github.com/agentconnect-md/agent-memory-template) 或默认 zero-LLM 模式的 [akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory)）则干脆不做模型分类评分。业界虽有「让模型输出结构化 JSON 指令再由确定性脚本执行」的讨论，但指令中的记忆内容仍由模型生成。**把本地模型严格限制为「只判留不留、归哪类、打几分」，而写入 `INBOX.md` 的文本 100% 机械截取人/agent 原始 `[事实]` 原句，这一硬约束在已调研项目中未见先例。**

2. **「`MEMORY.md` 硬预算 90 行，超了先合并，老条目进 `ARCHIVE.md`（熵控制）」—— 已有先例**
   - 先例项目：[letta-ai/letta](https://github.com/letta-ai/letta) 早已采用「Core Memory 块硬字符上限（默认 2,000 字符，超限报错）+ Archival Memory 归档」的分层预算设计；[supermemoryai/memoryrepo](https://github.com/supermemoryai/memoryrepo) 也要求保持 `MEMORY.md` 简短并由后台进程合并裁剪；此外 Claude Code 原生 `MEMORY.md` 也有行数/体积截断机制。我方的特色在于用无后台常驻服务的纯脚本体积自报 + `!!` 告警实现。

3. **「零云依赖：纯文本 + 本地小模型（Ollama）+ 脚本，不用向量库」—— 已有先例**
   - 先例项目：[agentconnect-md/agent-memory-template](https://github.com/agentconnect-md/agent-memory-template) 做到完全零数据库零云依赖；[basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory) 与 [akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory) 均支持完全本地离线运行。我方的局部差异是**连 SQLite 和 embedding 模型都不引入**，仅在离线整理时用 Ollama（加 JSON Schema 解码约束）做一次分类打分。

4. **「Windows PowerShell 与 Linux bash 双实现，两边各有约 40 项自测」—— 工程实践少见（有部分先例）**
   - 先例对比：[akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory) 用 Rust 原生同时覆盖了 Linux（systemd）与 Windows（无管理员权限 PowerShell 安装器）；其余绝大多数 Python/TS 项目依赖跨平台运行时，而 [agentconnect-md/agent-memory-template](https://github.com/agentconnect-md/agent-memory-template) 仅覆盖 macOS/Linux。我方不依赖 Python 包环境或编译二进制、直接用原生 `PowerShell 5.1+` 与 `bash` 双实现并自带 mock Ollama 自测（README 已实测标注 Linux `selftest.sh` 40 项断言全过；Windows 侧自测具体项数在已读文档中未明写，按「双实现 + 完整自测」表述更稳妥），在纯脚本记忆方案里比较少见。

---

### 3. 定位结论（三选一）

**选择：B. 定位缩小（聚焦强调「零幻觉、有硬预算的本地磁盘记忆层 —— 模型只做分类门控，不写记忆句子」）**

理由：
1. **避开同质化红海**：「Markdown 当长期记忆」「不用向量库/RAG」已经被 `memoryrepo`、`agent-memory-template`、`basic-memory`、`memsearch`、`ai-memory` 等项目充分覆盖，甚至已有 2,176 题的社区评测站台。继续把「纯 Markdown + 不用 RAG」作为主卖点，无法回答「为什么不用现成的 `memoryrepo` 或 `basic-memory`」。
2. **放大唯一不可替代的护城河**：现有方案（无论向量库、图谱还是 Markdown wiki）的共同痛点是**让 LLM 总结/改写记忆会引入二次幻觉与漂移**。我方「`[事实]` 原句直取 + 本地小模型只打标不造句」精准击中这一痛点，且在同类开源项目中未见先例。
3. **保留既有优势作支撑**：「90 行硬预算 + 一次调用快照 + 零云依赖双端脚本」作为实现这一零幻觉记忆层的工程保障，从「主定位」退居为「交付机制」，叙事会更锋利、更不易被质疑。

---

### 4. README "Related work" 段落草稿（中文，20 行）

```markdown
## Related work

市面上已经有多种解决 agent 长期记忆的思路，本仓库的定位和边界如下：

- **向量库 / 知识图谱 / 托管记忆服务**（如 [Mem0](https://github.com/mem0ai/mem0)、[Zep / Graphiti](https://github.com/getzep/graphiti)、[Cognee](https://github.com/topoteretes/cognee)、[LangMem](https://github.com/langchain-ai/langmem)、[Supermemory](https://github.com/supermemoryai/supermemory)）：适合海量对话与开放式语义检索，通常依赖 LLM 自动抽取/改写事实，并需要向量库、图数据库或服务端运行。
- **状态化 Agent 框架与分层内存**（如 [Letta / MemGPT](https://github.com/letta-ai/letta)）：同样采用「容量受限的常驻核心记忆 + 外部归档记忆」分层模型，但核心记忆块由 agent 自主改写，且绑定自身运行时。
- **Markdown 为真相源的本地记忆**（如 [memoryrepo](https://github.com/supermemoryai/memoryrepo)、[agent-memory-template](https://github.com/agentconnect-md/agent-memory-template)、[Basic Memory](https://github.com/basicmachines-co/basic-memory)、[memsearch](https://github.com/zilliztech/memsearch)、[ai-memory](https://github.com/akitaonrails/ai-memory)）：都坚持人类可读的 Markdown 文件作为 source of truth，或辅以 SQLite / Milvus / 本地 embedding 加速检索。

**`agent-memory-layer` 的差异在于两点：**
1. **模型只做分类门控，不写任何记忆文本**：本地小模型只对已标 `[事实]` 的原句打标签与打分，写入 `INBOX.md` 的内容 100% 原句直取，避免模型二次总结引入幻觉。
2. **极简纯脚本 + 硬预算快照**：不引入数据库、embedding 服务或常驻进程，仅靠 90 行封顶的 `MEMORY.md` 与单次 `recall` 快照交付开工上下文，适合只需要记住几十到上百条精确事实的个人工作流。
```
