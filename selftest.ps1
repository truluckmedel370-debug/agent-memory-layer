# selftest.ps1 —— PowerShell 版 agent-memory-layer 零依赖自测（路线 B，对齐 linux/selftest.sh）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File selftest.ps1

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$examplesDir = Join-Path $repoRoot 'examples'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Assert-True([bool]$Cond, [string]$Desc) {
  if ($Cond) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc" -ForegroundColor Red
    $script:Fail++
  }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Desc) {
  if ($Text.Contains($Needle)) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc (未找到: $Needle)" -ForegroundColor Red
    $script:Fail++
  }
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$Desc) {
  if (-not $Text.Contains($Needle)) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc (不应包含: $Needle)" -ForegroundColor Red
    $script:Fail++
  }
}

function Assert-Eq($Actual, $Expected, [string]$Desc) {
  if ($Actual -eq $Expected) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc (期望: '$Expected', 实际: '$Actual')" -ForegroundColor Red
    $script:Fail++
  }
}

function Run-PS([string]$ScriptPath, [string[]]$ScriptArgs = @()) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArgs
  $psi.Arguments = ($argList | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
  }) -join ' '
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Out      = ($stdout + "`n" + $stderr).Trim()
    StdOut   = $stdout
    StdErr   = $stderr
  }
}

$rand = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path $env:TEMP "amem-pester-$rand"
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

function Reset-Sandbox {
  Get-ChildItem -Path $sandbox -Filter '*.md' -ErrorAction SilentlyContinue | Remove-Item -Force
  Remove-Item -Path (Join-Path $sandbox '.digest-state.json') -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $examplesDir 'MEMORY.template.md') (Join-Path $sandbox 'MEMORY.md') -Force
  Copy-Item (Join-Path $examplesDir 'PENDING.template.md') (Join-Path $sandbox 'PENDING.md') -Force
  Copy-Item (Join-Path $examplesDir 'INBOX.template.md') (Join-Path $sandbox 'INBOX.md') -Force
  Copy-Item (Join-Path $examplesDir 'LOG.template.md') (Join-Path $sandbox 'LOG.md') -Force
  Copy-Item (Join-Path $examplesDir 'ARCHIVE.template.md') (Join-Path $sandbox 'ARCHIVE.md') -Force
}

foreach ($f in @('recall.ps1', 'remember.ps1', 'memo.ps1', 'ai.ps1')) {
  Copy-Item (Join-Path $repoRoot $f) (Join-Path $sandbox $f) -Force
}

# 启动本地 Mock Ollama HttpListener（使用独立 Runspace）
$tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$tcp.Start()
$mockPort = ([System.Net.IPEndPoint]$tcp.LocalEndpoint).Port
$tcp.Stop()

$mockState = [hashtable]::Synchronized(@{
  Mode     = 'normal'
  Requests = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  Running  = $true
})

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$mockPort/")
$listener.Start()

$psMock = [PowerShell]::Create()
$null = $psMock.AddScript({
  param($listener, $state)
  while ($state.Running -and $listener.IsListening) {
    try {
      $ctx = $listener.GetContext()
    } catch { break }
    $req = $ctx.Request
    $resp = $ctx.Response
    if ($req.Url.AbsolutePath -eq '/api/version') {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"version":"0.5.0-mock"}')
      $resp.ContentType = 'application/json'
      $resp.OutputStream.Write($bytes, 0, $bytes.Length)
      $resp.Close()
      continue
    }
    if ($req.Url.AbsolutePath -eq '/api/generate') {
      $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
      $raw = $sr.ReadToEnd()
      $sr.Close()
      $null = $state.Requests.Add($raw)
      $data = $raw | ConvertFrom-Json
      $mode = $state.Mode
      if ($mode -eq 'single_obj') {
        $respText = '{"i":1,"kind":"口径"}'
      } elseif ($mode -eq 'bad_json') {
        $respText = '完全不是JSON输出'
      } else {
        $arr = @()
        foreach ($line in ($data.prompt -split "`n")) {
          if ($line -match '^\[(\d+)\]\s*(.+)$') {
            $idx = [int]$Matches[1]
            $txt = $Matches[2].Trim()
            if ($txt -match '称呼|偏好') { $k = '身份' }
            elseif ($txt -match 'Ollama|端口|路径') { $k = '环境' }
            elseif ($txt -match '规范|不要') { $k = '口径' }
            elseif ($txt -match '踩坑|报错') { $k = '坑' }
            else { $k = '项目' }
            $arr += [ordered]@{ i = $idx; kind = $k }
          }
        }
        $respText = ConvertTo-Json -InputObject @($arr) -Compress
      }
      $outObj = [ordered]@{
        response      = $respText
        eval_count    = 42
        eval_duration = 500000000
      } | ConvertTo-Json -Compress
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($outObj)
      $resp.ContentType = 'application/json; charset=utf-8'
      $resp.OutputStream.Write($bytes, 0, $bytes.Length)
      $resp.Close()
      continue
    }
    $resp.StatusCode = 404
    $resp.Close()
  }
}).AddArgument($listener).AddArgument($mockState)
$mockHandle = $psMock.BeginInvoke()

# 创建 ai-mock-proxy.ps1 供 remember.ps1 通过 AMEM_AI_PS1 指向 Mock 端口
$proxyPath = Join-Path $sandbox 'ai-mock-proxy.ps1'
$proxyCode = @"
param(
  [string]`$Prompt,
  [string]`$Sys = '',
  [string]`$Model = '',
  [int]`$MaxTok = 700,
  [double]`$Temp = 0,
  [string]`$Fmt = 'text',
  [string]`$NoCache = '',
  [string]`$Schema = ''
)
& "$sandbox\ai.ps1" -Prompt `$Prompt -Sys `$Sys -Model `$Model -MaxTok `$MaxTok -Temp `$Temp -Fmt `$Fmt -NoCache `$NoCache -Schema `$Schema -Base "http://127.0.0.1:$mockPort"
"@
[System.IO.File]::WriteAllText($proxyPath, $proxyCode, (New-Object System.Text.UTF8Encoding($true)))

$oldAiEnv = $env:AMEM_AI_PS1

try {
  # =========================================================================
  Write-Host "`n=== A. 测试 recall.ps1 ==="
  Reset-Sandbox
  $logPath = Join-Path $sandbox 'LOG.md'
  $logInit = @"
# LOG · 流水

## 2026-11-24 10:00
- [事实] 第一条测试日志内容在这里
- [动作] 跑了一次测试动作一

## 2026-11-23 10:00
- [事实] 第二条测试日志内容在这里

## 2026-11-22 10:00
- [事实] 第三条测试日志内容在这里
"@
  [System.IO.File]::WriteAllText($logPath, $logInit, $utf8NoBom)

  $r1 = Run-PS (Join-Path $sandbox 'recall.ps1')
  Assert-Eq $r1.ExitCode 0 'A0: recall.ps1 退出码为 0'
  # 1. 回归：LOG 尾部必须是日志内容，不能是孤立的 ^15$ 行
  Assert-Contains $r1.Out '第一条测试日志内容在这里' 'A1: recall 回归 - LOG 输出包含实际日志内容'
  Assert-True (-not ($r1.Out -match '(?m)^15\r?$')) 'A1: recall 回归 - 不包含孤立的 ^15$ 行'

  # 2. 输出顺序：MEMORY -> PENDING -> INBOX -> LOG
  $iMem = $r1.Out.IndexOf('===== MEMORY.md')
  $iPend = $r1.Out.IndexOf('===== PENDING.md')
  $iInb = $r1.Out.IndexOf('===== INBOX.md')
  $iLog = $r1.Out.IndexOf('===== LOG.md')
  Assert-True ($iMem -ge 0 -and $iMem -lt $iPend -and $iPend -lt $iInb -and $iInb -lt $iLog) 'A2: 输出顺序 MEMORY -> PENDING -> INBOX -> LOG'

  # 3. INBOX 空/非空
  Assert-Contains $r1.Out '===== INBOX.md（待合并 0 条）=====' 'A3a: INBOX 空时标题显示 0 条'
  Assert-Contains $r1.Out '（空）' 'A3b: INBOX 空时输出（空）'
  $inbPath = Join-Path $sandbox 'INBOX.md'
  [System.IO.File]::WriteAllText($inbPath, ((Get-Content $inbPath -Raw -Encoding UTF8) + "`n- [ ] (环境|2) 测试候选一`n- [ ] (坑|2) 测试候选二`n"), $utf8NoBom)
  $rInb = Run-PS (Join-Path $sandbox 'recall.ps1')
  Assert-Contains $rInb.Out '===== INBOX.md（待合并 2 条）=====' 'A3c: INBOX 非空时标题显示待合并 2 条'
  Assert-Contains $rInb.Out '测试候选一' 'A3d: INBOX 非空时输出条目内容'

  # 4. -LogLines 3
  $r3 = Run-PS (Join-Path $sandbox 'recall.ps1') @('-LogLines', '3')
  Assert-Contains $r3.Out '===== LOG.md 最新 3 行 =====' 'A4a: -LogLines 3 标题正确'
  Assert-Contains $r3.Out '第三条测试日志内容在这里' 'A4b: -LogLines 3 包含尾部日志'
  Assert-NotContains $r3.Out '第一条测试日志内容在这里' 'A4c: -LogLines 3 不包含更早的顶部行'

  # 5. -Full
  $rFull = Run-PS (Join-Path $sandbox 'recall.ps1') @('-Full')
  Assert-Contains $rFull.Out '第一条测试日志内容在这里' 'A5a: -Full 包含顶部日志'
  Assert-Contains $rFull.Out '第三条测试日志内容在这里' 'A5b: -Full 包含底部日志'

  # 6. 末行字符数 N 精确核对
  $memTxt = [System.IO.File]::ReadAllText((Join-Path $sandbox 'MEMORY.md'), [System.Text.Encoding]::UTF8)
  $pendTxt = [System.IO.File]::ReadAllText((Join-Path $sandbox 'PENDING.md'), [System.Text.Encoding]::UTF8)
  $inbTxt = [System.IO.File]::ReadAllText((Join-Path $sandbox 'INBOX.md'), [System.Text.Encoding]::UTF8)
  $logTxt = [System.IO.File]::ReadAllText((Join-Path $sandbox 'LOG.md'), [System.Text.Encoding]::UTF8)
  $logTail = (($logTxt -split "`n") | Select-Object -Last 15) -join "`n"
  $expectedChars = $memTxt.Length + $pendTxt.Length + $inbTxt.Length + $logTail.Length
  $mFoot = [regex]::Match($rInb.Out, '\[快照 (\d+) 字符，约 ([\d,]+)-([\d,]+) token；MEMORY 预算 90 行，现在 (\d+) 行\]')
  Assert-True $mFoot.Success 'A6a: 末行自报格式匹配'
  if ($mFoot.Success) {
    Assert-Eq ([int]$mFoot.Groups[1].Value) $expectedChars 'A6b: 快照字符数 N 等于四文件实际字符数之和'
  }

  # 7. MEMORY 91 行告警
  $mem91 = (1..91 | ForEach-Object { "- 第 $_ 行记忆" }) -join "`n"
  [System.IO.File]::WriteAllText((Join-Path $sandbox 'MEMORY.md'), $mem91, $utf8NoBom)
  $r91 = Run-PS (Join-Path $sandbox 'recall.ps1')
  Assert-Contains $r91.Out '!! MEMORY 超预算：先把重复条目合并，再写新的' 'A7: MEMORY 91 行触发超预算告警'

  # =========================================================================
  Write-Host "`n=== B. 测试 remember.ps1 ==="
  $env:AMEM_AI_PS1 = $proxyPath
  $mockState.Mode = 'normal'
  $mockState.Requests.Clear()

  Reset-Sandbox
  $sampleLog = @"
# LOG · 流水

## 2026-11-24 10:00
- [事实] 主人称呼为老板，偏好简洁直接汇报
- [fact] 踩坑：PowerShell 5.1 必须用带 BOM 的 UTF-8 保存脚本
- [事实] 短句
- [动作] 跑了一次全量构建测试
- 无标记的一句话超过八个字但不该收

## 2026-11-23 10:00
- [事实] 这台机器的 Ollama 监听 127.0.0.1:11434，模型装在 D 盘
- [事实] 这台机器的 Ollama 监听 127.0.0.1:11434，模型装在 D 盘上
- [事实] 本次临时整理一下项目进度说明
"@
  [System.IO.File]::WriteAllText((Join-Path $sandbox 'LOG.md'), $sampleLog, $utf8NoBom)

  # 14. -DryRun
  $remDry = Run-PS (Join-Path $sandbox 'remember.ps1') @('-DryRun', '-NoAutoStart')
  Assert-Contains $remDry.Out 'LOG 2 条，已处理 0，新增待整理 2' 'B8: 正确分段为 2 条'
  Assert-Contains $remDry.Out '取到 [事实] 原句 5 条' 'B9/B10: 过滤短句/动作/无标记，保留 5 条 [事实]/[fact]'
  Assert-Contains $remDry.Out '~ 本轮重复，跳过：' 'B13a: bigram 相似度去重跳过重复句'
  Assert-Contains $remDry.Out '[DryRun] 将写入 INBOX.md：' 'B14a: -DryRun 输出计划写入'
  Assert-True (-not (Test-Path (Join-Path $sandbox '.digest-state.json'))) 'B14b: -DryRun 不写 .digest-state.json'
  Assert-NotContains ([System.IO.File]::ReadAllText((Join-Path $sandbox 'INBOX.md'), [System.Text.Encoding]::UTF8)) '老板' 'B14c: -DryRun 不写 INBOX.md'

  # 11 / 13 / 15. 真跑：分值、不同句都进、逐字一致
  $remReal = Run-PS (Join-Path $sandbox 'remember.ps1') @('-NoAutoStart')
  $inbAfter = [System.IO.File]::ReadAllText((Join-Path $sandbox 'INBOX.md'), [System.Text.Encoding]::UTF8)
  Assert-True ($inbAfter.Contains('- [ ] (身份|3) 主人称呼为老板，偏好简洁直接汇报')) 'B11/B15a: INBOX 逐字包含 身份|3 原句'
  Assert-True ($inbAfter.Contains('- [ ] (坑|2) 踩坑：PowerShell 5.1 必须用带 BOM 的 UTF-8 保存脚本')) 'B11/B15b: INBOX 逐字包含 坑|2 原句'
  Assert-True ($inbAfter.Contains('- [ ] (环境|2) 这台机器的 Ollama 监听 127.0.0.1:11434，模型装在 D 盘')) 'B11/B13b: 不同句正常入 INBOX'
  Assert-NotContains $inbAfter '项目进度说明' 'B11c: 项目类(分值1)被 MinScore=2 过滤'

  # 16. 二次运行幂等
  $remAgain = Run-PS (Join-Path $sandbox 'remember.ps1') @('-NoAutoStart')
  Assert-Contains $remAgain.Out '没有新流水需要整理' 'B16a: 二次运行输出没有新流水需要整理'
  $stJson = Get-Content (Join-Path $sandbox '.digest-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Eq ([int]$stJson.processed) 2 'B16b: processed 已推进到 2'

  # 12. -MinScore 3 + 20. -Reset + 9. -All
  Reset-Sandbox
  [System.IO.File]::WriteAllText((Join-Path $sandbox 'LOG.md'), $sampleLog, $utf8NoBom)
  $null = Run-PS (Join-Path $sandbox 'remember.ps1') @('-NoAutoStart')
  # 清空 INBOX 以便验证 -Reset -MinScore 3
  Copy-Item (Join-Path $examplesDir 'INBOX.template.md') (Join-Path $sandbox 'INBOX.md') -Force
  $remMin3 = Run-PS (Join-Path $sandbox 'remember.ps1') @('-Reset', '-MinScore', '3', '-NoAutoStart')
  $inbMin3 = [System.IO.File]::ReadAllText((Join-Path $sandbox 'INBOX.md'), [System.Text.Encoding]::UTF8)
  Assert-Contains $inbMin3 '(身份|3)' 'B12/B20a: -Reset -MinScore 3 保留 身份(3)'
  Assert-NotContains $inbMin3 '(坑|2)' 'B12b: -MinScore 3 过滤 坑(2)'
  Assert-NotContains $inbMin3 '(环境|2)' 'B12c: -MinScore 3 过滤 环境(2)'

  $remAll = Run-PS (Join-Path $sandbox 'remember.ps1') @('-Reset', '-All', '-DryRun', '-NoAutoStart')
  Assert-Contains $remAll.Out '取到 [事实] 原句 7 条' 'B9b: -All 收录 [动作] 与无标记长句（共 7 条）'

  # 17. 模型返回单对象 {...}
  $null = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Kind', 'log', '-Text', '[事实] 口径：所有脚本必须支持严格测试规范')
  $mockState.Mode = 'single_obj'
  $remSingle = Run-PS (Join-Path $sandbox 'remember.ps1') @('-NoAutoStart')
  Assert-Contains $remSingle.Out '写入 INBOX.md 1 条待合并' 'B17: 单对象 {...} 容错包成数组处理成功'

  # 18. 模型返回垃圾文本 -> 游标不动
  $null = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Kind', 'log', '-Text', '[事实] 环境：新增一条会触发失败的测试记录')
  $mockState.Mode = 'bad_json'
  $remBad = Run-PS (Join-Path $sandbox 'remember.ps1') @('-NoAutoStart')
  Assert-Contains $remBad.Out '没解析出 JSON' 'B18a: 垃圾文本报 没解析出 JSON'
  $stAfterBad = Get-Content (Join-Path $sandbox '.digest-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Eq ([int]$stAfterBad.processed) 3 'B18b: 失败后游标保持 3 不动'

  # 19. -Prune -DaysKeepLog 0
  $mockState.Mode = 'normal'
  $remPrune = Run-PS (Join-Path $sandbox 'remember.ps1') @('-Prune', '-DaysKeepLog', '0', '-NoAutoStart')
  Assert-Contains $remPrune.Out 'ARCHIVE.md' 'B19a: -Prune 输出归档到 ARCHIVE.md'
  $archTxt = [System.IO.File]::ReadAllText((Join-Path $sandbox 'ARCHIVE.md'), [System.Text.Encoding]::UTF8)
  $logAfterPrune = [System.IO.File]::ReadAllText((Join-Path $sandbox 'LOG.md'), [System.Text.Encoding]::UTF8)
  Assert-Contains $archTxt '2026-11-23 10:00' 'B19b: ARCHIVE.md 包含被归档段落'
  Assert-NotContains $logAfterPrune '2026-11-23 10:00' 'B19c: LOG.md 已移除被归档段落'

  # =========================================================================
  Write-Host "`n=== C. 测试 memo.ps1 ==="
  Reset-Sandbox
  $mLog = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Kind', 'log', '-Text', '[事实] 测试顶部插入的日志条目')
  Assert-Contains $mLog.Out '已写入 LOG.md 顶部：' 'C21a: memo -Kind log 返回提示'
  $logTop = [System.IO.File]::ReadAllText((Join-Path $sandbox 'LOG.md'), [System.Text.Encoding]::UTF8)
  $idxNew = $logTop.IndexOf('测试顶部插入的日志条目')
  $idxOld = $logTop.IndexOf('2026-01-01 12:00')
  Assert-True ($idxNew -ge 0 -and $idxNew -lt $idxOld) 'C21b: 新日志插在旧日志之上且带时间戳头'

  $mMem = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Kind', 'mem', '-Text', '测试写入长期记忆条目')
  Assert-Contains $mMem.Out '已追加到 MEMORY.md 尾部' 'C22a: memo -Kind mem 返回提示'
  Assert-Contains ([System.IO.File]::ReadAllText((Join-Path $sandbox 'MEMORY.md'), [System.Text.Encoding]::UTF8)) '测试写入长期记忆条目' 'C22b: MEMORY.md 写入成功'

  $mPend = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Kind', 'pending', '-Text', '- [ ] 测试写入待办事项')
  Assert-Contains $mPend.Out '已追加到 PENDING.md' 'C22c: memo -Kind pending 返回提示'
  Assert-Contains ([System.IO.File]::ReadAllText((Join-Path $sandbox 'PENDING.md'), [System.Text.Encoding]::UTF8)) '测试写入待办事项' 'C22d: PENDING.md 写入成功'

  $mHit = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Search', 'Ollama')
  Assert-True ($mHit.Out -match 'LOG\.md:\d+: .*Ollama') 'C23a: -Search 命中时输出 文件名:行号: 内容'
  $mMiss = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Search', '绝对不存在的关键词XYZ999')
  Assert-True ([string]::IsNullOrWhiteSpace($mMiss.Out)) 'C23b: -Search 未命中时无误报输出'

  $mShow = Run-PS (Join-Path $sandbox 'memo.ps1') @('-Show')
  Assert-Contains $mShow.Out '===== MEMORY.md =====' 'C24a: -Show 输出 MEMORY.md'
  Assert-Contains $mShow.Out '===== PENDING.md =====' 'C24b: -Show 输出 PENDING.md'

  # =========================================================================
  Write-Host "`n=== D. 测试 ai.ps1 ==="
  $mockState.Mode = 'normal'
  $mockState.Requests.Clear()
  $schema = '{"type":"array","items":{"type":"object","properties":{"i":{"type":"integer"},"kind":{"type":"string","enum":["身份","环境","口径","坑","项目"]}},"required":["i","kind"]}}'
  $aiSchema = Run-PS (Join-Path $sandbox 'ai.ps1') @('-Prompt', '[1] 用户偏好简洁输出', '-Model', 'test-m', '-Fmt', 'json', '-Schema', $schema, '-Base', "http://127.0.0.1:$mockPort")
  Assert-Eq $aiSchema.ExitCode 0 'D25a: ai.ps1 -Schema 调用成功'
  $req1 = $mockState.Requests[0] | ConvertFrom-Json
  Assert-True ($req1.format -is [pscustomobject] -and $req1.format.type -eq 'array') 'D25b: -Schema 时请求体 format 是解析后的对象而非字符串'

  $mockState.Requests.Clear()
  $aiFmt = Run-PS (Join-Path $sandbox 'ai.ps1') @('-Prompt', '[1] 用户偏好简洁输出', '-Model', 'test-m', '-Fmt', 'json', '-Base', "http://127.0.0.1:$mockPort")
  Assert-Eq $aiFmt.ExitCode 0 'D26a: ai.ps1 -Fmt json 调用成功'
  $req2 = $mockState.Requests[0] | ConvertFrom-Json
  Assert-Eq $req2.format 'json' 'D26b: -Fmt json（无 -Schema）时 format == "json"'

  $aiDead = Run-PS (Join-Path $sandbox 'ai.ps1') @('-Prompt', 'hi', '-Base', 'http://127.0.0.1:1', '-TimeoutSec', '2')
  Assert-Eq $aiDead.ExitCode 2 'D27a: Ollama 不可达时退出码为 2'
  Assert-Contains $aiDead.Out '!! Ollama 请求失败' 'D27b: Ollama 不可达时输出简洁错误提示'
}
finally {
  $env:AMEM_AI_PS1 = $oldAiEnv
  $mockState.Running = $false
  try { $listener.Stop() } catch {}
  try { $listener.Close() } catch {}
  try { $psMock.Dispose() } catch {}
  Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==============================="
Write-Host ("自测完成：PASS={0}, FAIL={1}" -f $script:Pass, $script:Fail)
Write-Host "==============================="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
