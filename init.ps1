# init.ps1 —— 把 examples/ 下的模板铺成真正的记忆文件（已存在的不覆盖）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File init.ps1 [-Force] [-Dir <记忆库目录>]

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$Dir = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

# 注意：PS 5.1 里参数默认值拿不到 $PSScriptRoot（绑定阶段是空），只能在函数体里兜
if (-not $Dir) { $Dir = $PSScriptRoot }

$enc  = New-Object System.Text.UTF8Encoding($false)
$tplD = Join-Path $PSScriptRoot 'examples'
$map  = [ordered]@{
  'MEMORY.template.md'  = 'MEMORY.md'
  'PENDING.template.md' = 'PENDING.md'
  'LOG.template.md'     = 'LOG.md'
  'INBOX.template.md'   = 'INBOX.md'
  'ARCHIVE.template.md' = 'ARCHIVE.md'
}

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }

foreach ($k in $map.Keys) {
  $src = Join-Path $tplD $k
  $dst = Join-Path $Dir $map[$k]
  if (-not (Test-Path $src)) { Write-Output "跳过（缺模板）：$k"; continue }
  if ((Test-Path $dst) -and -not $Force) { Write-Output "已存在，不动：$($map[$k])"; continue }
  $txt = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($dst, $txt, $enc)
  Write-Output "写入：$($map[$k])"
}

$stateP = Join-Path $Dir '.digest-state.json'
if (-not (Test-Path $stateP)) {
  $st = [ordered]@{ processed = 0; lastStamp = ''; updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); model = '' } | ConvertTo-Json
  [System.IO.File]::WriteAllText($stateP, $st, $enc)
  Write-Output "写入：.digest-state.json"
}

Write-Output ""
Write-Output "下一步："
Write-Output "  1) 先在 LOG.md 里追加一条 ## 时间戳 段落 + 带 [事实] 的 bullet"
Write-Output "  2) powershell -NoProfile -ExecutionPolicy Bypass -File remember.ps1 -DryRun"
Write-Output "  3) 满意后去掉 -DryRun 真跑，再 recall.ps1 看快照"
