# task-install.ps1 —— 注册 / 卸载「记忆整理」计划任务（带开机补跑）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File task-install.ps1 [-Mode on|off|status]

[CmdletBinding()]
param([ValidateSet('on','off','status')][string]$Mode = 'status')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tn   = 'DeepSeekMemoryDigest'
$tpl  = Join-Path $dir 'digest-task.xml'
$user = "$env:USERDOMAIN\$env:USERNAME"

switch ($Mode) {
  'status' {
    $q = schtasks /Query /TN $tn /XML 2>&1 | Out-String
    if ($q -match 'StartWhenAvailable') {
      Write-Output "[已注册] 触发：每天 23:40 + 登录后 5 分钟（错过自动补跑）"
      Write-Output ("         执行：{0}" -f ((schtasks /Query /TN $tn /XML 2>&1 | Out-String) -replace '(?s).*<Command>(.*?)</Command>.*','$1'))
    } else { Write-Output "[未注册] 跑 task-install.ps1 -Mode on 开启" }
  }
  'off' {
    $r = schtasks /Delete /TN $tn /F 2>&1 | Out-String
    Write-Output $r.Trim()
  }
  'on' {
    if (-not (Test-Path $tpl)) { throw "缺少模板 $tpl" }
    $x = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
    $x = $x.Replace('__USER__', $user)
    $x = $x.Replace('__CMD__', "`"$dir\digest-run.cmd`"")
    $x = $x.Replace('__DIR__', $dir)
    # schtasks 要求 XML 声明与文件编码一致，这里写 UTF-16
    $x = $x.Replace('encoding="UTF-8"', 'encoding="UTF-16"')
    $tmp = Join-Path $env:TEMP ("dsh-digest-{0}.xml" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($tmp, $x, (New-Object System.Text.UnicodeEncoding($false, $true)))
    $r = schtasks /Create /TN $tn /XML $tmp /F 2>&1 | Out-String
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Output $r.Trim()
    Write-Output "触发：每天 23:40 + 每次登录后 5 分钟（关机错过的会补跑）"
  }
}
