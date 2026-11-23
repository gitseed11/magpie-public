@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0control.ps1" -Action stop
exit /b %ERRORLEVEL%