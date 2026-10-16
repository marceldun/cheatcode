@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-start.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
