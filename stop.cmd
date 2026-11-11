@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set "PORT=8790"
set "METRICS=20242"
set "UPSTREAM=3425"

REM ==========================================================================
REM  stop.cmd - stop the public API only.
REM
REM  Kills exactly three things that belong to this folder:
REM    * node.exe        ...magpie-public\proxy.js   (the auth proxy)
REM    * cloudflared.exe ...magpie-public\...        (the tunnel)
REM    * powershell.exe  ...magpie-public\run.ps1    (the watchdog)
REM
REM  Magpie (127.0.0.1:3425) and any other service are never touched.
REM  Safe to run when nothing is running: it just reports that.
REM  Equivalent to: start.cmd stop   (kept standalone on purpose, so it still
REM  works if start.cmd is missing or being edited).
REM ==========================================================================

echo [*] Stopping Magpie public API (proxy + tunnel + watchdog) ...
echo     Magpie on %UPSTREAM% keeps running and is not touched.

REM Two passes: the watchdog can spawn a fresh proxy between enumerating the
REM process list and killing it. Ancestors of this script are excluded,
REM because the powershell/cmd chain below carries the project path too.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$anc = @(); $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID);" ^
  "while ($p) { $anc += $p.ProcessId; $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p.ParentProcessId) -ErrorAction SilentlyContinue };" ^
  "$killed = @();" ^
  "foreach ($pass in 1..2) {" ^
  "  $targets = Get-CimInstance Win32_Process | Where-Object {" ^
  "    $anc -notcontains $_.ProcessId -and $_.CommandLine -and (" ^
  "      ($_.Name -eq 'node.exe'        -and $_.CommandLine -like '*magpie-public*proxy.js*') -or" ^
  "      ($_.Name -eq 'cloudflared.exe' -and ($_.CommandLine -like '*magpie-public*' -or $_.ExecutablePath -like '*magpie-public*')) -or" ^
  "      ($_.Name -eq 'powershell.exe'  -and $_.CommandLine -like '*magpie-public*run.ps1*')" ^
  "    ) };" ^
  "  foreach ($t in $targets) {" ^
  "    Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue;" ^
  "    $killed += ($t.Name + ' pid ' + $t.ProcessId); Start-Sleep -Milliseconds 150 };" ^
  "  Start-Sleep -Milliseconds 700 };" ^
  "if ($killed.Count -eq 0) { Write-Host '[i] Nothing was running.' }" ^
  "else { Write-Host ('[OK] Killed: ' + (($killed | Select-Object -Unique) -join ', ')) }"

REM Give the OS a moment to release the sockets, then verify.
powershell -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1

set "STILL="
netstat -an | findstr /C:"127.0.0.1:%PORT%" | findstr /C:"LISTENING" >nul
if not errorlevel 1 set "STILL=proxy %PORT%"
netstat -an | findstr /C:"127.0.0.1:%METRICS%" | findstr /C:"LISTENING" >nul
if not errorlevel 1 set "STILL=!STILL! tunnel %METRICS%"

if defined STILL (
    echo [X] Still listening: !STILL!
    echo     Something else may own these ports. Inspect with: netstat -ano
    exit /b 1
)

echo [OK] Stopped. Ports %PORT% and %METRICS% are free.
netstat -an | findstr /C:"127.0.0.1:%UPSTREAM%" | findstr /C:"LISTENING" >nul
if errorlevel 1 (
    echo [i] Magpie is not listening on %UPSTREAM% either ^(it was already stopped^).
) else (
    echo [i] Magpie still running on %UPSTREAM% ^(untouched^).
)
echo     Restart the public API with start.cmd
exit /b 0
