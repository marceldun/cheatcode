@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 恢复配置前状态 v2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0恢复.ps1"
echo.
pause

