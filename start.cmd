@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PORT=8790"
set "METRICS=20242"
set "UPSTREAM=3425"

if /i "%~1"=="stop"   goto :stop
if /i "%~1"=="status" goto :status

REM ------------------------------------------------------------------ start
REM The watchdog is what keeps proxy + tunnel alive. Checking only the port
REM would silently accept a leftover process set whose supervisor is gone
REM (then nothing restarts the tunnel if it dies), so check the watchdog too.
call :hassup
if not errorlevel 1 (
    echo [i] Watchdog already running.
    goto :report
)

netstat -an | findstr /C:"127.0.0.1:%PORT%" | findstr /C:"LISTENING" >nul
if not errorlevel 1 (
    echo [X] Port %PORT% is in use but the watchdog is NOT running.
    echo     That is a leftover state from killing processes by hand; nothing
    echo     would restart the tunnel if it dropped. Run:
    echo.
    echo         start.cmd stop
    echo         start.cmd
    echo.
    exit /b 1
)

echo [*] Starting Magpie public API ...
start "" wscript.exe "%~dp0launch.vbs"

set /a n=0
:wait
REM Use PowerShell's Start-Sleep instead of `timeout`, which is shadowed by
REM a different timeout.exe in some shells (e.g. Git Bash).
powershell -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1
netstat -an | findstr /C:"127.0.0.1:%PORT%" | findstr /C:"LISTENING" >nul
if not errorlevel 1 goto :report
set /a n+=1
if !n! lss 20 goto :wait

echo [X] Did not come up within 40s. See logs\supervisor.log
exit /b 1

REM ----------------------------------------------------------------- report
:report
echo.
echo   Proxy    : 127.0.0.1:%PORT%   [OK]
echo   Metrics  : 127.0.0.1:%METRICS%
echo   Public   : https://apimagpie.example.com/v1
echo   API key  : see API-KEY.txt in this folder
echo.

netstat -an | findstr /C:"127.0.0.1:%UPSTREAM%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (
    echo   [!] Magpie is NOT running on port %UPSTREAM% right now.
    echo       The tunnel is up, but public calls will return 502 until
    echo       you start Magpie. No action needed here -- it will start
    echo       working as soon as Magpie is listening on %UPSTREAM%.
) else (
    echo   Magpie   : 127.0.0.1:%UPSTREAM%   [OK]
)
echo.
exit /b 0

REM ----------------------------------------------------------------- status
:status
call :hassup
if errorlevel 1 (echo Watchdog: STOPPED) else (echo Watchdog: running)
netstat -an | findstr /C:"127.0.0.1:%PORT%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (echo Proxy : STOPPED) else (echo Proxy : running on %PORT%)
netstat -an | findstr /C:"127.0.0.1:%METRICS%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (echo Tunnel: STOPPED) else (echo Tunnel: running, metrics %METRICS%)
netstat -an | findstr /C:"127.0.0.1:%UPSTREAM%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (echo Magpie: not running) else (echo Magpie: running on %UPSTREAM%)
exit /b 0

REM ------------------------------------------------------------------- stop
:stop
echo [*] Stopping ...
REM NOTE: stop.cmd contains the same kill logic as this block (it exists so
REM the public side can be stopped without start.cmd). Keep the two in sync.
REM Kill every process that belongs to this project (proxy, tunnel, watchdog).
REM Match process NAME and command line, and exclude this process's own
REM ancestors: the powershell/cmd chain that invoked us also carries the
REM project path in its command line and would otherwise kill itself.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$self = $PID;" ^
  "$ancestors = @();" ^
  "$p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $self);" ^
  "while ($p) { $ancestors += $p.ProcessId; $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p.ParentProcessId) -ErrorAction SilentlyContinue };" ^
  "Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('node.exe','cloudflared.exe','powershell.exe') -and $_.CommandLine -like '*magpie-public*' -and $ancestors -notcontains $_.ProcessId } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
powershell -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1
netstat -an | findstr /C:"127.0.0.1:%PORT%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (echo [OK] Stopped.) else (echo [X] Still running; close remaining processes manually.)
exit /b 0

REM ---------------------------------------------------------------- helpers
:hassup
REM Is run.ps1 (the watchdog) running? Exclude this PowerShell process itself:
REM its own command line contains the search pattern and would self-match.
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*magpie-public*run.ps1*' }) { exit 0 } else { exit 1 }" >nul 2>&1
if errorlevel 1 (exit /b 1) else (exit /b 0)
