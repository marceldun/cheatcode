@echo off
chcp 65001 >nul
cd /d "%~dp0"
title WhatsApp 本地开源AI外贸业务员 v4
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0安装部署.ps1"
echo.
pause

