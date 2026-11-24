# recall.ps1 —— 一次调用输出记忆快照（替代逐个读 4 个文件，省 3 次往返）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File recall.ps1 [-LogLines 15] [-Full]

[CmdletBinding()]
param(
  [int]$LogLines = 15,
  [switch]$Full
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$enc  = [System.Text.Encoding]::UTF8
function Read-Memo($n) { $p = Join-Path $root $n; if (Test-Path $p) { [System.IO.File]::ReadAllText($p, $enc) } else { '' } }

$mem  = Read-Memo 'MEMORY.md'
$pend = Read-Memo 'PENDING.md'
$inb  = Read-Memo 'INBOX.md'
$log  = Read-Memo 'LOG.md'

$memLines = ($mem -split "`n").Count
$inboxCount = ([regex]::Matches($inb, '(?m)^- \[ \]')).Count

Write-Output "===== MEMORY.md（$memLines 行）====="
Write-Output $mem.TrimEnd()
Write-Output ""
Write-Output "===== PENDING.md ====="
Write-Output $pend.TrimEnd()
Write-Output ""
Write-Output "===== INBOX.md（待合并 $inboxCount 条）====="
if ($inboxCount -gt 0) { Write-Output $inb.TrimEnd() } else { Write-Output "（空）" }
Write-Output ""
Write-Output "===== LOG.md 最新 $LogLines 行 ====="
$lines = $log -split "`n"
if ($Full) { Write-Output $log.TrimEnd() } else { Write-Output (($lines | Select-Object -Last $LogLines) -join "`n").TrimEnd() }
Write-Output ""
$chars = $mem.Length + $pend.Length + $inb.Length + (($lines | Select-Object -Last $LogLines) -join "`n").Length
Write-Output ("[快照 {0} 字符，约 {1:N0}-{2:N0} token；MEMORY 预算 90 行，现在 {3} 行]" -f $chars, ($chars / 1.6), ($chars / 1.2), $memLines)
if ($memLines -gt 90) { Write-Output "!! MEMORY 超预算：先把重复条目合并，再写新的" }
