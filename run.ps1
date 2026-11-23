# Magpie public API - supervisor
#
# Starts the authenticating proxy and Cloudflare tunnel, and keeps them alive.
# Runs hidden (see launch.vbs). Magpie itself is observed but never restarted.

$ErrorActionPreference = 'Stop'
$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir    = Join-Path $Here 'logs'
$PidDir    = Join-Path $Here 'run'
$TunnelCfg = Join-Path $Here 'config.yml'
$CfExe     = Join-Path $Here 'bin\cloudflared.exe'
$ProxyJs   = Join-Path $Here 'proxy.js'
$SyncKey   = Join-Path $Here 'sync-key.ps1'
$MaxChildLogBytes = 4MB

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $PidDir | Out-Null
. (Join-Path $Here 'common.ps1')

function Write-Log([string]$Message) {
    # Logging must never be able to kill the watchdog (disk full, ACL drift,
    # locked file, rotation failure). Keep this entire function non-throwing.
    try {
        $path = Join-Path $LogDir 'supervisor.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 4MB) {
            Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction Stop
        }
        $line = "{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        try { [Console]::Error.WriteLine("supervisor log unavailable: $Message") } catch {}
    }
}

# Validate once before creating children. Invalid/non-loopback configuration is
# fatal; a missing cloudflared binary remains a soft failure so the proxy can
# still enforce loopback auth and report a useful 503/502 to local diagnostics.
try {
    $Config = Get-MagpiePublicConfig -Root $Here
    $Tunnel = Get-MagpieTunnelConfig -Root $Here
    Assert-MagpiePublicBinding -Config $Config -Tunnel $Tunnel
    $NodeExe = Find-MagpieNodeExe
    if (-not $NodeExe) { throw 'node.exe was not found.' }
    if (-not (Test-Path -LiteralPath $ProxyJs -PathType Leaf)) { throw 'proxy.js is missing.' }
    $Port = $Config.ListenPort
    $UpstreamPort = $Config.UpstreamPort
    $metrics = $Tunnel.MetricsAddress
} catch {
    Write-Log "fatal startup validation failed: $($_.Exception.Message)"
    exit 1
}

# --- single instance guard -------------------------------------------------
$LockPath = Join-Path $PidDir 'supervisor.lock'
try {
    $script:LockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
} catch {
    exit 0
}
$supervisorPidPath = Join-Path $PidDir 'supervisor.pid'
try { $PID | Set-Content -LiteralPath $supervisorPidPath -Encoding ASCII } catch {}

function Get-ExitCode {
    param($Proc)
    try { $Proc.WaitForExit(2000) | Out-Null } catch {}
    try {
        $code = $Proc.ExitCode
        if ($null -ne $code) { return "code $code" }
    } catch {}
    return 'exit code unavailable'
}

function Reset-RedirectLogs {
    param([Parameter(Mandatory=$true)][string]$BaseName)
    foreach ($stream in @('out','err')) {
        $path = Join-Path $LogDir ($BaseName + '.' + $stream + '.log')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction Stop } catch {}
        }
    }
}

function Start-Proxy {
    Write-Log "starting proxy on $($Config.ListenHost):$Port"
    Reset-RedirectLogs -BaseName 'proxy'
    $p = Start-Process -FilePath $NodeExe -ArgumentList ('"{0}"' -f $ProxyJs) `
        -WorkingDirectory $Here -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir 'proxy.out.log') `
        -RedirectStandardError  (Join-Path $LogDir 'proxy.err.log')
    $p.Id | Set-Content -LiteralPath (Join-Path $PidDir 'proxy.pid') -Encoding ASCII
    return $p
}

function Start-Tunnel {
    if (-not (Test-Path -LiteralPath $TunnelCfg -PathType Leaf)) {
        Write-Log 'config.yml missing; tunnel not started'
        return $null
    }
    if (-not (Test-Path -LiteralPath $CfExe -PathType Leaf)) {
        Write-Log 'cloudflared.exe missing; tunnel not started'
        return $null
    }

    Write-Log "starting cloudflared tunnel (metrics $metrics)"
    Reset-RedirectLogs -BaseName 'cloudflared'
    # Local-config mode keeps the tunnel token out of the process command line.
    $cfArgs = @(
        'tunnel',
        '--config', ('"{0}"' -f $TunnelCfg),
        '--no-autoupdate',
        '--metrics', $metrics,
        'run'
    ) -join ' '
    $p = Start-Process -FilePath $CfExe -ArgumentList $cfArgs `
        -WorkingDirectory $Here -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir 'cloudflared.out.log') `
        -RedirectStandardError  (Join-Path $LogDir 'cloudflared.err.log')
    $p.Id | Set-Content -LiteralPath (Join-Path $PidDir 'cloudflared.pid') -Encoding ASCII
    return $p
}

function Test-TunnelLogsOversized {
    foreach ($stream in @('out','err')) {
        $path = Join-Path $LogDir ('cloudflared.' + $stream + '.log')
        try {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -gt $MaxChildLogBytes) {
                return $true
            }
        } catch {}
    }
    return $false
}

# --- supervisor loop -------------------------------------------------------
Write-Log "supervisor starting (proxy port $Port, upstream $UpstreamPort, metrics $metrics)"
$proxyProc  = $null
$tunnelProc = $null
$magpieWasUp = $null
$proxyHealthWas = $null
$tunnelNotReadyCount = 0
$lastProxyStart  = [datetime]::MinValue
$lastTunnelStart = [datetime]::MinValue

try {
while ($true) {
    try {
        # Keep the human-readable key file on the same settingsPath as the proxy.
        if (Test-Path -LiteralPath $SyncKey -PathType Leaf) {
            try { & $SyncKey } catch { Write-Log "key sync failed: $($_.Exception.Message)" }
        }

        # Magpie reachability is informational only; it is not ours to restart.
        $magpieUp = Test-MagpieTcp -HostName (Get-MagpieUriHost $Config.Upstream) -Port $UpstreamPort -TimeoutMs 1500
        if ($null -eq $magpieWasUp) {
            if ($magpieUp) { Write-Log "Magpie reachable on $UpstreamPort" }
            else { Write-Log "Magpie NOT reachable on $UpstreamPort (public calls will 502 until it starts)" }
        } elseif ($magpieUp -ne $magpieWasUp) {
            if ($magpieUp) { Write-Log "Magpie reachable on $UpstreamPort again" }
            else { Write-Log "Magpie NOT reachable on $UpstreamPort (public calls will 502 until it is back)" }
        }
        $magpieWasUp = $magpieUp

        # ---- proxy ----
        $proxyAlive = $false
        if ($proxyProc -and -not $proxyProc.HasExited) { $proxyAlive = $true }
        if ($proxyProc -and $proxyProc.HasExited) {
            Write-Log "proxy process exited ($(Get-ExitCode $proxyProc))"
        }
        if ($proxyAlive) {
            $health = Get-MagpieProxyHealth -Port $Port -HostName $Config.ListenHost -TimeoutMs 5000
            if ($proxyHealthWas -ne $health.State) {
                Write-Log "proxy health: $($health.State)"
                $proxyHealthWas = $health.State
            }
            # 401/429 prove auth is enforcing. 503 proves the process is alive
            # but the key is unavailable: degraded, NOT a reason to restart.
            if (-not $health.Alive) {
                Write-Log "proxy process alive but unhealthy ($($health.State)); restarting"
                try { Stop-Process -Id $proxyProc.Id -Force -ErrorAction Stop } catch {}
                Start-Sleep -Milliseconds 1500
                $proxyAlive = $false
            }
        }
        if (-not $proxyAlive) {
            if (((Get-Date) - $lastProxyStart).TotalSeconds -lt 5) { Start-Sleep -Seconds 5 }
            try {
                $proxyProc = Start-Proxy
                $proxyHealthWas = $null
                $lastProxyStart = Get-Date
            } catch {
                Write-Log "proxy start failed: $($_.Exception.Message)"
            }
        }

        # ---- tunnel ----
        $tunnelAlive = $false
        if ($tunnelProc -and -not $tunnelProc.HasExited) {
            $ready = Test-MagpieTunnelReady -MetricsAddress $metrics -TimeoutMs 5000
            if ($ready) {
                $tunnelAlive = $true
                $tunnelNotReadyCount = 0
            } else {
                $tunnelNotReadyCount += 1
                if ($tunnelNotReadyCount -eq 1) {
                    Write-Log 'tunnel not ready (1/3); allowing cloudflared to reconnect'
                }
                # cloudflared already reconnects. Only three consecutive failed
                # readiness checks justify killing it and losing in-flight work.
                if ($tunnelNotReadyCount -lt 3) {
                    $tunnelAlive = $true
                } else {
                    Write-Log 'tunnel not ready for 3 consecutive checks; restarting'
                    try { Stop-Process -Id $tunnelProc.Id -Force -ErrorAction Stop } catch {}
                    Start-Sleep -Milliseconds 1500
                    $tunnelNotReadyCount = 0
                }
            }
            # Redirected cloudflared logs otherwise grow for the whole process
            # lifetime. Rotate by a supervised restart only when they exceed 4MB.
            if ($tunnelAlive -and (Test-TunnelLogsOversized)) {
                Write-Log 'cloudflared log exceeded 4 MB; rotating by supervised restart'
                try { Stop-Process -Id $tunnelProc.Id -Force -ErrorAction Stop } catch {}
                Start-Sleep -Milliseconds 1500
                $tunnelAlive = $false
                $tunnelNotReadyCount = 0
            }
        }
        if (-not $tunnelAlive) {
            if ($tunnelProc -and $tunnelProc.HasExited) {
                Write-Log "tunnel process exited ($(Get-ExitCode $tunnelProc))"
                $tunnelNotReadyCount = 0
            }
            if (((Get-Date) - $lastTunnelStart).TotalSeconds -lt 5) { Start-Sleep -Seconds 5 }
            try {
                $tunnelProc = Start-Tunnel
                $lastTunnelStart = Get-Date
            } catch {
                Write-Log "tunnel start failed: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Log "loop error (continuing): $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 15
}
} finally {
    try { if ($script:LockStream) { $script:LockStream.Dispose() } } catch {}
    try {
        if ((Get-Content -LiteralPath $supervisorPidPath -ErrorAction SilentlyContinue | Select-Object -First 1) -eq [string]$PID) {
            Remove-Item -LiteralPath $supervisorPidPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
