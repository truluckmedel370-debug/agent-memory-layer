@echo off
chcp 65001 >nul
rem digest runner for scheduled task: remember.ps1 -Prune, output appended to digest.log
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remember.ps1" -Prune >> "%~dp0digest.log" 2>&1
