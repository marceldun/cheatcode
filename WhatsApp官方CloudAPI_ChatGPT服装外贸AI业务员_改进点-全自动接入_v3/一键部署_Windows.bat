@echo off
chcp 65001 >nul
cd /d "%~dp0"
title WhatsApp Cloud API + ChatGPT AI业务员 v3
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0部署.ps1"
echo.
pause

