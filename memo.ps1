# memo.ps1 —— 记忆库写入 / 检索（主人和 deepseek 都用这个）

[CmdletBinding()]
param(
  [ValidateSet('log','mem','pending')][string]$Kind = 'log',
  [string]$Text,
  [string]$Search,
  [switch]$Show
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = $PSScriptRoot
$enc  = New-Object System.Text.UTF8Encoding($false)

function Read-All($p) { if (Test-Path $p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { '' } }
function Write-All($p, $s) { [System.IO.File]::WriteAllText($p, $s, $enc) }

if ($Show -or (-not $Text -and -not $Search)) {
  Write-Output "===== MEMORY.md ====="
  Write-Output (Read-All "$root\MEMORY.md")
  Write-Output ""
  Write-Output "===== PENDING.md ====="
  Write-Output (Read-All "$root\PENDING.md")
  return
}

if ($Search) {
  Get-ChildItem $root -Filter *.md | ForEach-Object {
    $name = $_.Name
    $i = 0
    foreach ($line in ([System.IO.File]::ReadAllLines($_.FullName, [System.Text.Encoding]::UTF8))) {
      $i++
      if ($line -like "*$Search*") { Write-Output ("{0}:{1}: {2}" -f $name, $i, $line) }
    }
  }
  return
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

switch ($Kind) {
  'log' {
    $p = "$root\LOG.md"
    $s = Read-All $p
    $entry = "## $stamp`n- $Text`n`n"
    $idx = $s.IndexOf("`n## ")
    if ($idx -ge 0) { $s = $s.Insert($idx + 1, $entry) } else { $s = $s + "`n" + $entry }
    Write-All $p $s
    Write-Output "已写入 LOG.md 顶部：$stamp"
  }
  'mem' {
    $p = "$root\MEMORY.md"
    $s = Read-All $p
    if (-not $s.EndsWith("`n")) { $s += "`n" }
    Write-All $p ($s + "- $stamp ｜ $Text`n")
    Write-Output "已追加到 MEMORY.md 尾部"
  }
  'pending' {
    $p = "$root\PENDING.md"
    $s = Read-All $p
    if (-not $s.EndsWith("`n")) { $s += "`n" }
    Write-All $p ($s + "$Text`n")
    Write-Output "已追加到 PENDING.md"
  }
}
