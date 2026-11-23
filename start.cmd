@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "ACTION=start"
if /i "%~1"=="start" set "ACTION=start"
if /i "%~1"=="stop" set "ACTION=stop"
if /i "%~1"=="restart" set "ACTION=restart"
if /i "%~1"=="status" set "ACTION=status"
if not "%~1"=="" if /i not "%~1"=="start" if /i not "%~1"=="stop" if /i not "%~1"=="restart" if /i not "%~1"=="status" (
    echo Usage: start.cmd [start^|stop^|restart^|status]
    exit /b 2
)
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0control.ps1" -Action %ACTION%
exit /b %ERRORLEVEL%