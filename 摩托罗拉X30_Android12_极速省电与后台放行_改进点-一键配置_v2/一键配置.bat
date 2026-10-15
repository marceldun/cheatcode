@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 摩托罗拉 X30 极速省电与后台放行 v2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0配置.ps1"
echo.
pause

