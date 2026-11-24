# ai.ps1 —— 本地 Ollama 单次问答（remember.ps1 的模型接口层）
#
# 与 remember.ps1 的调用签名严格对齐：
#   & ai.ps1 -Prompt "..." -Sys "..." -Model qwen3-4b:q4 -MaxTok 700 -Temp 0 -Fmt text -NoCache yes
# -Fmt json     → 强制模型输出合法 JSON（Ollama 的 format 字段）
# -Schema <json> → 更强的约束：把整个 JSON Schema 交给 Ollama 当解码语法（推荐，根是数组时必用）
# -NoCache      → 保留参数（兼容旧调用）；本脚本无缓存层，忽略即可
#
# 依赖：Ollama 在 11434 上跑着（没跑就 ollama serve）

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Prompt,
  [string]$Sys = '',
  [string]$Model = '',
  [int]$MaxTok = 700,
  [double]$Temp = 0,
  [ValidateSet('text', 'json')][string]$Fmt = 'text',
  [string]$NoCache = '',
  [string]$Schema = '',
  [string]$Base = 'http://127.0.0.1:11434',
  [int]$TimeoutSec = 300,
  [switch]$ShowMeta
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

# 模型默认值：环境变量优先，其次 qwen3-4b（分类/打标够用，3.3 GB）
if (-not $Model) {
  $Model = if ($env:AMEM_MODEL) { $env:AMEM_MODEL } else { 'qwen3-4b:q4' }
}

$body = [ordered]@{
  model   = $Model
  prompt  = $Prompt
  stream  = $false
  options = [ordered]@{
    temperature = $Temp
    num_predict = $MaxTok
  }
}
if ($Sys) { $body['system'] = $Sys }
# -Schema 优先：直接把一个 JSON Schema 交给 Ollama 当语法约束（根节点是数组时模型才肯输出数组）
if ($Schema) {
  $body['format'] = ($Schema | ConvertFrom-Json)
} elseif ($Fmt -eq 'json') {
  $body['format'] = 'json'
}

$json = $body | ConvertTo-Json -Depth 6 -Compress

try {
  $r = Invoke-RestMethod -Uri "$Base/api/generate" -Method Post -Body $json `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
} catch {
  Write-Output "!! Ollama 请求失败（$Base）：$($_.Exception.Message)"
  Write-Output "   先确认服务：ollama serve    或    (Invoke-RestMethod $Base/api/version).version"
  exit 2
}

if ($ShowMeta) {
  [Console]::Error.WriteLine(("[{0} | eval {1} tok | {2:N1}s]" -f `
    $Model, $r.eval_count, ($r.eval_duration / 1e9)))
}

Write-Output ([string]$r.response).Trim()
