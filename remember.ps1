# remember.ps1 —— 自动记忆整理器 v2（本地 Ollama 只负责分类/打分，字面内容不过模型）
#
# 设计原则：模型会瞎编，所以不让它写句子。它只对 LOG 里的原句打标（kind + score + 是否已覆盖），
#           写入 INBOX 的事实文本一律取原句，幻觉面为零。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File remember.ps1            # 增量整理
#   ... -File remember.ps1 -Prune                                             # 归档老化流水 + 体检
#   ... -File remember.ps1 -DryRun                                            # 只看结果，不写文件
#   ... -File remember.ps1 -Model abl-8b:q4                                   # 要质量换 8B
#   ... -File remember.ps1 -Reset                                             # 重头处理全部 LOG（慎用）

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Prune,
  [switch]$Reset,
  [switch]$All,
  [switch]$NoAutoStart,
  [int]$DaysKeepLog = 60,
  [string]$Model = 'qwen3-4b:q4',
  [int]$MinScore = 2,
  [int]$BatchSize = 10
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

$root   = $PSScriptRoot
$logP   = Join-Path $root 'LOG.md'
$memP   = Join-Path $root 'MEMORY.md'
$inboxP = Join-Path $root 'INBOX.md'
$archP  = Join-Path $root 'ARCHIVE.md'
$stateP = Join-Path $root '.digest-state.json'
$aiP    = if ($env:AMEM_AI_PS1) { $env:AMEM_AI_PS1 } else { Join-Path $PSScriptRoot 'ai.ps1' }
$enc    = New-Object System.Text.UTF8Encoding($false)

function Read-All($p) { if (Test-Path $p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { '' } }
function Write-All($p, $s) { [System.IO.File]::WriteAllText($p, $s, $enc) }

# ---------- 0. 前置：Ollama 不在就自己拉起来 ----------
if (-not (Test-Path $aiP)) { Write-Output "!! 找不到 $aiP"; exit 2 }
$ollamaUp = $false
try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 4; $ollamaUp = $true } catch {}
if (-not $ollamaUp -and -not $NoAutoStart) {
  $exe = @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", 'C:\Program Files\Ollama\ollama.exe', 'D:\ollama\ollama.exe') |
         Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($exe) {
    Write-Output "Ollama 未运行，拉起：$exe serve"
    try { Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden } catch { Write-Output "  拉起失败：$($_.Exception.Message)" }
    Start-Sleep -Seconds 8
    try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 6; $ollamaUp = $true } catch {}
  }
}
if (-not $ollamaUp) { Write-Output "!! Ollama 起不来（11434 无响应），本次不整理，游标不动，下次再来"; exit 2 }

# ---------- 0b. 目录与文件 ----------
if (-not (Test-Path $inboxP)) {
  Write-All $inboxP "# INBOX · 待合并的长期事实候选`n`n> 由 remember.ps1 自动产出（原句直取，不经模型改写）。`n> deepseek 开工时逐条审核：并进 ``MEMORY.md`` 对应小节后删除该行。`n`n"
}
if (-not (Test-Path $archP)) {
  Write-All $archP "# ARCHIVE · 归档`n`n> 超过 ${DaysKeepLog} 天的流水。只读不删，需要时 grep。`n`n"
}

# ---------- 1. 状态与 LOG ----------
$state = @{ lastStamp = '0000-00-00 00:00' }
if ((Test-Path $stateP) -and -not $Reset) { try { $state = Get-Content $stateP -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

$logText = Read-All $logP
function Get-Entries([string]$text) {
  $out = @(); $cur = $null
  foreach ($ln in ($text -split "`n")) {
    if ($ln -match '^##\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
      if ($cur) { $out += $cur }
      $cur = [pscustomobject]@{ stamp = $Matches[1]; head = $ln; body = @() }
    } elseif ($cur) { $cur.body += $ln }
  }
  if ($cur) { $out += $cur }
  return $out
}
$entries = @(Get-Entries $logText)

# 游标按「已处理条数」算：LOG 新条目永远插在最上，所以新条目 = 最上面那几条。
# 用时间戳会把时钟偏差 / 手写时间戳算错，这里只把时间戳当展示用。
$processed = 0
if ($state.PSObject.Properties.Name -contains 'processed') { $processed = [int]$state.processed }
elseif ($state.lastStamp) {
  # 迁移：时间戳 <= 旧游标的都算已处理
  $processed = @($entries | Where-Object { [string]::CompareOrdinal($_.stamp, [string]$state.lastStamp) -le 0 }).Count
}
if ($Reset) { $processed = 0 }
$processed = [math]::Min($processed, $entries.Count)

$newCount = [math]::Max(0, $entries.Count - $processed)
$new = @(); if ($newCount -gt 0) { $new = @($entries[0..($newCount - 1)]) }
Write-Output ("LOG {0} 条，已处理 {1}，新增待整理 {2}" -f $entries.Count, $processed, $new.Count)

# ---------- 2. 老化归档 ----------
if ($Prune) {
  $cut = (Get-Date).AddDays(-$DaysKeepLog)
  $old = @($entries | Where-Object { [datetime]::ParseExact($_.stamp, 'yyyy-MM-dd HH:mm', $null) -lt $cut })
  if ($old.Count -gt 0) {
    $block = ($old | ForEach-Object { $_.head + "`n" + (($_.body -join "`n").TrimEnd()) }) -join "`n`n"
    $keep  = @($entries | Where-Object { [datetime]::ParseExact($_.stamp, 'yyyy-MM-dd HH:mm', $null) -ge $cut })
    if (-not $DryRun) {
      Write-All $archP ((Read-All $archP) + "`n" + $block + "`n")
      $head = "# LOG · 流水（新条目在最上）`n`n> 每条 bullet 标性质：``[事实]`` 值得长期留 / ``[动作]`` 只是一次动作。`n> 只追加，不改旧条。`n`n"
      $bodyText = ($keep | Sort-Object stamp -Descending | ForEach-Object { $_.head + "`n" + (($_.body -join "`n").TrimEnd()) }) -join "`n`n"
      Write-All $logP ($head + $bodyText + "`n")
      $entries   = @(Get-Entries (Read-All $logP))
      $processed = [math]::Min($processed, $entries.Count)
      $newCount  = [math]::Max(0, $entries.Count - $processed)
      $new = @(); if ($newCount -gt 0) { $new = @($entries[0..($newCount - 1)]) }
    }
    Write-Output ("归档 {0} 条 → ARCHIVE.md（>{1} 天）" -f $old.Count, $DaysKeepLog)
  } else { Write-Output "无需归档（没有超过 $DaysKeepLog 天的条目）" }

  $memLines = ((Read-All $memP) -split "`n").Count
  if ($memLines -gt 120) { Write-Output "!! MEMORY.md $memLines 行，超预算 120，该合并压缩" } else { Write-Output "MEMORY.md $memLines 行（预算 120）" }
}

if ($new.Count -eq 0) { Write-Output "没有新流水需要整理。"; exit 0 }

# ---------- 3. 从新增流水里取「[事实]」原句 ----------
# 约定：LOG 里每条 bullet 自己标好性质 —— [事实] 值得长期留 / [动作] 只是一次动作
# 这样精度不靠模型猜，靠写日志时的判断；模型只负责归类（身份/环境/口径/坑）
$items = @()
foreach ($e in $new) {
  foreach ($ln in $e.body) {
    $t = $ln.Trim()
    if ($t -match '^-+\s*(\S.*)$') { $t = $Matches[1].Trim() } else { continue }
    if ($t.StartsWith('#')) { continue }
    if ($t -match '^\[(事实|fact)\]\s*(.+)$') { $t = $Matches[2].Trim() }
    elseif ($t -match '^\[(动作|进度|action)\]\s*(.+)$') { if (-not $All) { continue }; $t = $Matches[2].Trim() }
    elseif (-not $All) { continue }   # 没打标的默认不当事实
    if ($t.Length -lt 8) { continue }
    $items += [pscustomobject]@{ text = $t; stamp = $e.stamp }
  }
}
Write-Output ("取到 [事实] 原句 {0} 条" -f $items.Count)
if ($items.Count -eq 0) {
  Write-Output "没有 [事实] 条目要整理（[动作] 不入库）。"
  if (-not $DryRun) {
    # 纯 [动作] 的条目也要记成已处理，否则游标永远卡在这里
    $out = [ordered]@{ processed = $entries.Count; lastStamp = ''; updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); model = $Model } | ConvertTo-Json
    Write-All $stateP $out
    Write-Output ("已处理 {0} 条（无事实可提）" -f $entries.Count)
  }
  exit 0
}

# ---------- 4. 已有记忆（给模型看，判断是否已覆盖；也给脚本做机械去重） ----------
$existing = @()
foreach ($l in ((Read-All $memP) -split "`n")) { if ($l -match '^\s*[-*]\s+\S' -and $l.Length -gt 12) { $existing += $l.Trim() } }
foreach ($l in ((Read-All $inboxP) -split "`n")) { if ($l -match '^\s*-\s+\[' -and $l.Length -gt 12) { $existing += ($l.Trim() -replace '^- \[.\]\s*\([^)]*\)\s*', '') } }
$existingBrief = (@($existing | Select-Object -First 50) | ForEach-Object { "- " + ($_ -replace '^- \[.\]\s*\([^)]*\)\s*', '') }) -join "`n"
if (-not $existingBrief) { $existingBrief = '（暂无）' }

function Get-BiGrams([string]$s) {
  $s = ($s -replace '[\s`*_\[\]()（）「」"''’‘，。、：；！？,.:;!?|—\-~→]+', '')
  $set = @{}
  if ($s.Length -lt 2) { if ($s.Length -eq 1) { $set[$s] = 1 }; return $set }
  for ($i = 0; $i -lt $s.Length - 1; $i++) { $set[$s.Substring($i, 2)] = 1 }
  return $set
}
function Similarity([string]$a, [string]$b) {
  $setA = Get-BiGrams $a; $setB = Get-BiGrams $b
  if ($setA.Count -eq 0 -or $setB.Count -eq 0) { return 0 }
  $inter = 0
  foreach ($k in $setA.Keys) { if ($setB.ContainsKey($k)) { $inter++ } }
  $jac = $inter / ($setA.Count + $setB.Count - $inter)
  $cov = $inter / [math]::Min($setA.Count, $setB.Count)
  return [math]::Round([math]::Max($jac, $cov * 0.9), 3)
}

$sysPrompt = @'
你是记忆分类器。给你一批「工作流水原句」（带编号），逐句判类，不要改写句子。

类别只能选一个：
- 身份 = 主人的身份、称谓、长期偏好、明确禁项
- 环境 = 这台机器的路径、软件、配置、账号、目录结构
- 口径 = 做事的方法与标准（以后该怎么做、不要怎么做）
- 坑 = 踩过的错、会反复出问题的地方
- 项目 = 具体某件事的进度、某次动作、某个产出（做完就过期）

判断诀窍：这句话是「描述了以后都要遵守／会反复用到的事实」，还是「记录某次做了什么」。
后者一律 项目。拿不准也选 项目（宁可漏记，不要污染记忆）。

只输出 JSON 数组：[{"i":1,"kind":"口径"},{"i":2,"kind":"项目"}]
每个编号必须出现且只出现一次。不要输出解释，不要输出其他文字。
'@

$sysPrompt = $sysPrompt + "`n【已记录的长期记忆，仅供判断参考，不要评论】`n" + $existingBrief

# 类别 → 分值（硬编码，不让模型决定分数）
function Get-Score([string]$kind) {
  switch ($kind.Trim()) {
    '身份' { return 3 }
    '环境' { return 2 }
    '口径' { return 2 }
    '坑'   { return 2 }
    default { return 1 }   # 项目 / 其它：只留在 LOG，不往 MEMORY 提
  }
}

# ---------- 5. 分批问模型 ----------
# 输出结构交给 Ollama 的语法约束来保证：根必须是数组、每个元素必须带 i 和 kind。
# 只给 format:"json" 不够 —— 小模型会返回单个对象、还会漏编号，正则就整批作废。
$schema = @'
{"type":"array","items":{"type":"object","properties":{"i":{"type":"integer"},"kind":{"type":"string","enum":["身份","环境","口径","坑","项目"]}},"required":["i","kind"]}}
'@
$labels = @{}
$failed = $false
$batches = [math]::Ceiling($items.Count / $BatchSize)
for ($b = 0; $b -lt $batches; $b++) {
  $from = $b * $BatchSize
  $to   = [math]::Min($from + $BatchSize - 1, $items.Count - 1)
  $chunk = $items[$from..$to]
  $numbered = for ($i = 0; $i -lt $chunk.Count; $i++) { "[{0}] {1}" -f ($from + $i + 1), $chunk[$i].text }
  $prompt = ($numbered -join "`n") + "`n`n输出 JSON："
  Write-Output ("  批次 {0}/{1}：{2} 句 → {3}" -f ($b + 1), $batches, $chunk.Count, $Model)

  try { $raw = [string](& $aiP -Prompt $prompt -Sys $sysPrompt -Model $Model -MaxTok 700 -Temp 0 -Fmt json -Schema $schema -NoCache yes) }
  catch { Write-Output ("  !! 模型调用失败：{0}" -f $_.Exception.Message); $failed = $true; continue }

  # 容错：数组优先，其次单个对象（模型偶发只回一个），都没有才算失败
  $m = [regex]::Match($raw, '(?s)\[[\s\S]*\]')
  if ($m.Success) { $jsonText = $m.Value }
  else {
    $m1 = [regex]::Match($raw, '(?s)\{[\s\S]*\}')
    if (-not $m1.Success) { Write-Output "  !! 没解析出 JSON，跳过这批"; $failed = $true; continue }
    $jsonText = '[' + $m1.Value + ']'
  }
  try { $arr = $jsonText | ConvertFrom-Json } catch { Write-Output "  !! JSON 非法，跳过这批"; $failed = $true; continue }

  foreach ($it in @($arr)) {
    $idx = [int]$it.i
    if ($idx -lt 1 -or $idx -gt $items.Count) { continue }
    $k = [string]$it.kind
    $labels[$idx] = [pscustomobject]@{ kind = $k; score = (Get-Score $k) }
  }
}

# ---------- 6. 过滤 + 机械去重 ----------
$picked = @()
for ($i = 0; $i -lt $items.Count; $i++) {
  $n = $i + 1
  if (-not $labels.ContainsKey($n)) { Write-Output ("  x 模型漏标，待人工看：{0}" -f $items[$i].text); continue }
  $lb = $labels[$n]
  if ($lb.score -lt $MinScore) { continue }

  $dup = $null
  foreach ($e in $existing) { if ((Similarity $items[$i].text $e) -ge 0.55) { $dup = $e; break } }
  if ($dup) { Write-Output ("  ~ 已覆盖，跳过：{0}" -f $items[$i].text); continue }

  $dup2 = $null
  foreach ($p in $picked) { if ((Similarity $items[$i].text $p.text) -ge 0.55) { $dup2 = $p.text; break } }
  if ($dup2) { Write-Output ("  ~ 本轮重复，跳过：{0}" -f $items[$i].text); continue }

  $picked += [pscustomobject]@{ text = $items[$i].text; kind = $lb.kind; score = $lb.score; stamp = $items[$i].stamp }
}

# ---------- 7. 写 INBOX ----------
$nowShort = (Get-Date -Format 'MM-dd HH:mm')
if ($picked.Count -eq 0) { Write-Output "本轮没有达标的新事实。" }
else {
  $add = ($picked | ForEach-Object { "- [ ] ({0}|{1}) {2}  ← {3}" -f $_.kind, $_.score, $_.text, $_.stamp }) -join "`n"
  if ($DryRun) { Write-Output "`n[DryRun] 将写入 INBOX.md："; Write-Output $add }
  else {
    $inbox = Read-All $inboxP
    if (-not $inbox.EndsWith("`n")) { $inbox += "`n" }
    Write-All $inboxP ($inbox + "`n<!-- 整理于 $nowShort -->`n" + $add + "`n")
    Write-Output ("`n写入 INBOX.md {0} 条待合并" -f $picked.Count)
  }
}

# ---------- 8. 推进游标 ----------
# 有批次失败就不推进：否则这几句会被永久跳过，等于静默丢记忆
if ($failed) {
  Write-Output "!! 有批次没跑成功，游标保持不动，下次自动重试这几句（本次已入队的不会重复，靠去重挡）"
}
elseif (-not $DryRun) {
  $newest = ''
  if ($new.Count -gt 0) { $newest = ($new | Sort-Object stamp | Select-Object -Last 1).stamp }
  $out = [ordered]@{
    processed = $entries.Count
    lastStamp = $newest
    updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    model     = $Model
  } | ConvertTo-Json
  Write-All $stateP $out
  Write-Output ("已处理 {0}/{1} 条（游标推进到第 {0} 条）" -f $entries.Count, $entries.Count)
}
