# Magpie public API - supervisor
#
# Starts the authenticating proxy and the Cloudflare tunnel, and keeps them
# alive. Runs hidden (see launch.vbs). Writes logs next to itself.
#
# This script only touches files under its own folder. It never modifies
# Magpie's configuration and never touches any other service on the machine.

$ErrorActionPreference = 'Stop'
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir  = Join-Path $Here 'logs'
$PidDir  = Join-Path $Here 'run'
$TunnelCfg = Join-Path $Here 'config.yml'
$CfExe   = Join-Path $Here 'bin\cloudflared.exe'
# Pinned path first (standard Node.js install), then auto-detect from PATH so
# the same folder works on another PC without editing the script.
$NodeExe = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path -LiteralPath $NodeExe)) {
    $found = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($found) { $NodeExe = $found.Source }
}
$ProxyJs = Join-Path $Here 'proxy.js'
$SyncKey = Join-Path $Here 'sync-key.ps1'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $PidDir | Out-Null

# --- single instance guard -------------------------------------------------
# Two supervisors would fight over the same ports and log files. Hold an
# exclusive handle on a lock file for the lifetime of this process; the OS
# releases it automatically when we exit, even on a hard kill.
$LockPath = Join-Path $PidDir 'supervisor.lock'
try {
    $script:LockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
} catch {
    # Another supervisor already holds the lock: exit quietly.
    exit 0
}

function Write-Log([string]$Message) {
    $path = Join-Path $LogDir 'supervisor.log'
    # Keep the supervisor log bounded too; it writes every 15 seconds forever.
    try {
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 4MB) {
            Move-Item -LiteralPath $path -Destination ($path + '.1') -Force
        }
    } catch {}
    $line = "{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $path -Value $line -Encoding utf8
}

# --- proxy health: TCP connect + a deliberately wrong key must be refused ----
function Test-Proxy {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $client.Close()
    } catch { return $false }

    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/v1/models")
        $req.Method = 'GET'
        $req.KeepAlive = $false
        $req.Proxy = $null
        $req.Timeout = 5000
        $req.Headers.Add('Authorization', 'Bearer definitely-not-the-key')
        # NOTE: User-Agent is a *restricted* header on HttpWebRequest --
        # Headers.Add('User-Agent', ...) throws ArgumentException, which used to
        # make this whole probe return $false and the supervisor kill a healthy
        # proxy every 15 seconds. It must be set through the typed property.
        # Mark the probe so it is distinguishable from a real bad-key attempt
        # in proxy.log (the proxy logs the caller identity on every decision).
        $req.UserAgent = 'magpie-public-supervisor-healthcheck'
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
        }
        if ($null -eq $resp) { return $false }
        $code = [int]$resp.StatusCode
        $resp.Close()
        # Healthy = "answering and refusing". 401 is the normal path; 429 means
        # the local bucket is saturated, which still proves the proxy is up and
        # enforcing. A 200 here would mean auth was bypassed -- treat as bad.
        return ($code -eq 401 -or $code -eq 429)
    } catch { return $false }
}

# --- tunnel readiness: cloudflared exposes /ready on its metrics port -------
# Process liveness alone is not enough: cloudflared can stay alive while its
# edge connections are down, and then the public hostname is broken even
# though the process "looks fine".
function Test-TunnelReady {
    param([string]$MetricsAddr)
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://$MetricsAddr/ready")
        $req.Method = 'GET'
        $req.Timeout = 5000
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch { return $false }
}

# --- is Magpie itself listening? (informational, not a restart trigger) -----
function Test-Magpie {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $client.Close()
        return $true
    } catch { return $false }
}

function Get-ExitCode {
    param($Proc)
    # ExitCode is not always populated right after a force-kill; wait briefly.
    try { $Proc.WaitForExit(2000) | Out-Null } catch {}
    try {
        $code = $Proc.ExitCode
        if ($null -ne $code) { return "code $code" }
    } catch {}
    return 'exit code unavailable'
}

function Get-ProxyPort {
    $cfg = Get-Content (Join-Path $Here 'config.json') -Raw | ConvertFrom-Json
    if ($cfg.listenPort) { return [int]$cfg.listenPort }
    return 8790
}

function Get-UpstreamPort {
    # Informational only: used to explain 502s in the log, never to restart
    # anything (a proxy restart cannot bring Magpie back, and it is not ours).
    try {
        $cfg = Get-Content (Join-Path $Here 'config.json') -Raw | ConvertFrom-Json
        if ($cfg.upstream) {
            $u = [uri]$cfg.upstream
            if ($u.Port -gt 0) { return [int]$u.Port }
        }
    } catch {}
    return 3425
}

# --- start helpers ---------------------------------------------------------

function Start-Proxy {
    param([int]$Port)
    Write-Log "starting proxy on 127.0.0.1:$Port"
    # Quote the script path: this project lives under a path with spaces.
    $p = Start-Process -FilePath $NodeExe -ArgumentList ('"{0}"' -f $ProxyJs) `
        -WorkingDirectory $Here -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir 'proxy.out.log') `
        -RedirectStandardError  (Join-Path $LogDir 'proxy.err.log')
    $p.Id | Set-Content (Join-Path $PidDir 'proxy.pid')
    return $p
}

function Get-MetricsAddr {
    # Read metrics from config.yml so the port is maintained in one place only.
    # Falls back to 127.0.0.1:20242 when the key is absent.
    try {
        $line = Select-String -Path $TunnelCfg -Pattern '^\s*metrics:\s*(\S+)' -ErrorAction Stop |
                Select-Object -First 1
        if ($line -and $line.Matches.Count -gt 0) {
            $addr = $line.Matches[0].Groups[1].Value.Trim().Trim("'", '"')
            if ($addr) { return $addr }
        }
    } catch {}
    return '127.0.0.1:20242'
}

function Start-Tunnel {
    if (-not (Test-Path $TunnelCfg)) {
        Write-Log 'config.yml missing; tunnel not started'
        return $null
    }
    if (-not (Test-Path $CfExe)) {
        Write-Log 'cloudflared.exe missing; tunnel not started'
        return $null
    }

    $metrics = Get-MetricsAddr
    Write-Log "starting cloudflared tunnel (metrics $metrics)"
    # Local-config mode: tunnel id + credentials + ingress all come from
    # config.yml, so no token ever appears on the command line.
    # Every path is quoted because this project lives under a path with spaces.
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
    $p.Id | Set-Content (Join-Path $PidDir 'cloudflared.pid')
    return $p
}

# --- supervisor loop -------------------------------------------------------

$Port = Get-ProxyPort
$UpstreamPort = Get-UpstreamPort
$metrics = Get-MetricsAddr
Write-Log "supervisor starting (proxy port $Port, upstream $UpstreamPort, metrics $metrics)"

$proxyProc  = $null
$tunnelProc = $null
$magpieWasUp = $null
$lastProxyStart  = [datetime]::MinValue
$lastTunnelStart = [datetime]::MinValue

while ($true) {
    # A transient error must never kill the supervisor: log it and keep going.
    try {
    # ---- keep API-KEY.txt in sync with Magpie's current lanKey ----
    if (Test-Path $SyncKey) {
        try { & $SyncKey } catch { Write-Log "key sync failed: $($_.Exception.Message)" }
    }

    # ---- Magpie reachability: log state changes only (no restarts) ----
    # The proxy needs no restart when Magpie comes or goes: it opens a fresh
    # upstream connection per request. This line just explains 502s.
    $magpieUp = Test-Magpie -Port $UpstreamPort
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
    # Note: Start-Process truncates the redirect files on each start, so the
    # previous instance's stderr is lost. Log the exit code here instead.
    if ($proxyProc -and $proxyProc.HasExited) {
        Write-Log "proxy process exited ($(Get-ExitCode $proxyProc))"
    }
    if ($proxyAlive -and -not (Test-Proxy -Port $Port)) {
        # process exists but is not answering: treat as dead
        Write-Log 'proxy process alive but unresponsive; restarting'
        try { Stop-Process -Id $proxyProc.Id -Force } catch {}
        # Give the OS a moment to release the listening socket before rebinding.
        Start-Sleep -Milliseconds 1500
        $proxyAlive = $false
    }
    if (-not $proxyAlive) {
        if (((Get-Date) - $lastProxyStart).TotalSeconds -lt 5) {
            Start-Sleep -Seconds 5
        }
        try {
            $proxyProc = Start-Proxy -Port $Port
            $lastProxyStart = Get-Date
        } catch {
            Write-Log "proxy start failed: $($_.Exception.Message)"
        }
    }

    # ---- tunnel ----
    $tunnelAlive = $false
    if ($tunnelProc -and -not $tunnelProc.HasExited) {
        # Process is up; also require the edge connection to be ready.
        if (Test-TunnelReady -MetricsAddr $metrics) {
            $tunnelAlive = $true
        } else {
            Write-Log 'tunnel process alive but not ready; restarting'
            try { Stop-Process -Id $tunnelProc.Id -Force } catch {}
            # Let the old process release the metrics port before the new one binds.
            Start-Sleep -Milliseconds 1500
        }
    }
    if (-not $tunnelAlive) {
        if ($tunnelProc -and $tunnelProc.HasExited) {
            Write-Log "tunnel process exited ($(Get-ExitCode $tunnelProc))"
        }
        if (((Get-Date) - $lastTunnelStart).TotalSeconds -lt 5) {
            Start-Sleep -Seconds 5
        }
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
