# Single implementation for start / stop / restart / status.
# start.cmd and stop.cmd are compatibility wrappers; panel.ps1 uses -Json.

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start','stop','restart','status')]
    [string]$Action,
    [switch]$Json,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'common.ps1')
New-Item -ItemType Directory -Force -Path (Join-Path $Here 'logs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Here 'run') | Out-Null

function Get-PublicStatus {
    param([Parameter(Mandatory=$true)][hashtable]$Paths)

    $owned = @(Get-MagpieOwnedProcesses -Root $Paths.Root)
    $supervisor = @($owned | Where-Object { $_.MagpieRole -eq 'supervisor' })
    $proxy = @($owned | Where-Object { $_.MagpieRole -eq 'proxy' })
    $tunnel = @($owned | Where-Object { $_.MagpieRole -eq 'tunnel' })
    $proxyListening = Test-MagpiePortListening -Port $Paths.Config.ListenPort
    $metricsListening = Test-MagpiePortListening -Port $Paths.Tunnel.MetricsPort

    $health = $null
    if ($proxyListening) { $health = Get-MagpieProxyHealth -Port $Paths.Config.ListenPort -HostName $Paths.Config.ListenHost -TimeoutMs 2500 }
    $tunnelReady = $false
    if ($metricsListening) { $tunnelReady = Test-MagpieTunnelReady -MetricsAddress $Paths.Tunnel.MetricsAddress -TimeoutMs 2500 }
    $magpieUp = Test-MagpieTcp -HostName (Get-MagpieUriHost $Paths.Config.Upstream) -Port $Paths.Config.UpstreamPort -TimeoutMs 1200

    $state = 'degraded'
    if ($owned.Count -eq 0) {
        $state = 'stopped'
    } elseif ($supervisor.Count -gt 0 -and $proxy.Count -gt 0 -and $health -and $health.Ready -and $tunnel.Count -gt 0 -and $tunnelReady) {
        if ($magpieUp) { $state = 'ready' } else { $state = 'waiting-upstream' }
    }

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($proxyListening -and $proxy.Count -eq 0) { $warnings.Add('Proxy port is owned by another process.') | Out-Null }
    if ($metricsListening -and $tunnel.Count -eq 0) { $warnings.Add('Metrics port is owned by another process.') | Out-Null }
    if ($supervisor.Count -eq 0 -and ($proxy.Count -gt 0 -or $tunnel.Count -gt 0)) { $warnings.Add('Orphaned public components have no watchdog.') | Out-Null }

    return [pscustomobject][ordered]@{
        state       = $state
        endpoint    = $Paths.Tunnel.PublicEndpoint
        watchdog    = [pscustomobject]@{
            running = $supervisor.Count -gt 0
            pids    = @($supervisor | ForEach-Object { $_.ProcessId })
        }
        proxy       = [pscustomobject]@{
            running            = $proxy.Count -gt 0
            pids               = @($proxy | ForEach-Object { $_.ProcessId })
            listening          = $proxyListening
            health             = if ($health) { $health.State } else { 'unreachable' }
            httpStatus         = if ($health) { $health.StatusCode } else { 0 }
            address            = (Format-MagpieHost $Paths.Config.ListenHost) + ':' + $Paths.Config.ListenPort
            portOwnedByOther   = $proxyListening -and $proxy.Count -eq 0
        }
        tunnel      = [pscustomobject]@{
            running            = $tunnel.Count -gt 0
            pids               = @($tunnel | ForEach-Object { $_.ProcessId })
            metricsListening   = $metricsListening
            ready              = $tunnelReady
            metrics            = $Paths.Tunnel.MetricsAddress
            portOwnedByOther   = $metricsListening -and $tunnel.Count -eq 0
        }
        magpie      = [pscustomobject]@{
            reachable = $magpieUp
            address   = (Format-MagpieHost (Get-MagpieUriHost $Paths.Config.Upstream)) + ':' + $Paths.Config.UpstreamPort
            controlledByTheseScripts = $false
        }
        warnings    = $warnings.ToArray()
        checkedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
    }
}

function Stop-PublicProcesses {
    param([Parameter(Mandatory=$true)][hashtable]$Paths)
    $stopped = New-Object 'System.Collections.Generic.List[string]'

    # Stop the watchdog first and wait for it to exit so it cannot respawn the
    # children between the two child passes. Every stop requires exact ownership.
    foreach ($role in @('supervisor','proxy','tunnel')) {
        $targets = @(Get-MagpieOwnedProcesses -Root $Paths.Root -Role $role)
        foreach ($target in $targets) {
            try {
                Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
                $stopped.Add("$role pid $($target.ProcessId)") | Out-Null
            } catch {
                if (Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue) { throw }
            }
        }
        $deadline = (Get-Date).AddSeconds(6)
        do {
            $remaining = @($targets | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
            if ($remaining.Count -eq 0) { break }
            Start-Sleep -Milliseconds 150
        } while ((Get-Date) -lt $deadline)
        if ($remaining.Count -gt 0) { throw "Could not stop owned $role process(es)." }
    }

    if (@(Get-MagpieOwnedProcesses -Root $Paths.Root).Count -eq 0) {
        foreach ($name in @('supervisor.pid','proxy.pid','cloudflared.pid')) {
            $path = Join-Path $Paths.Root ('run\' + $name)
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $stopped.ToArray()
}

function Write-TextStatus($Status) {
    Write-Output ('State   : ' + $Status.state)
    Write-Output ('Watchdog: ' + $(if ($Status.watchdog.running) { 'running' } else { 'STOPPED' }))
    Write-Output ('Proxy   : ' + $(if ($Status.proxy.running) { 'running' } else { 'STOPPED' }) + '; ' + $Status.proxy.health + '; ' + $Status.proxy.address)
    Write-Output ('Tunnel  : ' + $(if ($Status.tunnel.running) { 'running' } else { 'STOPPED' }) + '; ready=' + $Status.tunnel.ready + '; metrics ' + $Status.tunnel.metrics)
    Write-Output ('Magpie  : ' + $(if ($Status.magpie.reachable) { 'reachable (independent; never stopped by this tool)' } else { 'not reachable' }) + '; ' + $Status.magpie.address)
    Write-Output ('Public  : ' + $Status.endpoint)
    foreach ($warning in $Status.warnings) { Write-Output ('Warning : ' + $warning) }
}

function Get-ExitCodeForState([string]$State) {
    switch ($State) {
        'ready' { return 0 }
        'waiting-upstream' { return 0 }
        'stopped' { return 1 }
        default { return 2 }
    }
}

$paths = @{
    Root   = $Here
    Config = $null
    Tunnel = $null
}

try {
    $paths.Config = Get-MagpiePublicConfig -Root $Here
    $paths.Tunnel = Get-MagpieTunnelConfig -Root $Here
    Assert-MagpiePublicBinding -Config $paths.Config -Tunnel $paths.Tunnel

    if ($Action -eq 'status') {
        $status = Get-PublicStatus -Paths $paths
        if ($Json) { $status | ConvertTo-Json -Depth 6 -Compress } else { Write-TextStatus $status }
        exit (Get-ExitCodeForState $status.state)
    }

    if ($Action -in @('stop','restart')) {
        $stopped = @(Stop-PublicProcesses -Paths $paths)
        Start-Sleep -Milliseconds 500
        $status = Get-PublicStatus -Paths $paths
        $leftovers = @(Get-MagpieOwnedProcesses -Root $Here)
        $result = [pscustomobject]@{
            action   = $Action
            stopped  = $stopped
            status   = $status
            success  = $leftovers.Count -eq 0
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 6 -Compress
        } else {
            if ($stopped.Count -eq 0) { Write-Output '[i] Nothing owned by this folder was running.' }
            else { Write-Output ('[OK] Stopped: ' + ($stopped -join ', ')) }
            Write-TextStatus $status
        }
        if ($leftovers.Count -gt 0) { exit 2 }
        if ($Action -eq 'stop') { exit 0 }
    }

    # Start (or the start half of restart). Clean only owned orphans. A foreign
    # listener is a conflict, never a reason to kill that process.
    $ownedSupervisor = @(Get-MagpieOwnedProcesses -Root $Here -Role 'supervisor')
    if ($ownedSupervisor.Count -eq 0) {
        $orphans = @(Get-MagpieOwnedProcesses -Root $Here | Where-Object { $_.MagpieRole -ne 'supervisor' })
        if ($orphans.Count -gt 0) { Stop-PublicProcesses -Paths $paths | Out-Null }
        if (Test-MagpiePortListening -Port $paths.Config.ListenPort) {
            throw "Port $($paths.Config.ListenPort) is occupied by a process not owned by this folder."
        }
        if (Test-MagpiePortListening -Port $paths.Tunnel.MetricsPort) {
            throw "Metrics port $($paths.Tunnel.MetricsPort) is occupied by a process not owned by this folder."
        }
        if (-not (Find-MagpieNodeExe)) { throw 'node.exe was not found.' }
        $vbs = Join-Path $Here 'launch.vbs'
        if (-not (Test-Path -LiteralPath $vbs -PathType Leaf)) { throw 'launch.vbs is missing.' }
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs) -WorkingDirectory $Here -WindowStyle Hidden | Out-Null
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(5, $TimeoutSeconds))
    do {
        Start-Sleep -Seconds 2
        $status = Get-PublicStatus -Paths $paths
        $componentsUp = $status.watchdog.running -and $status.proxy.running -and
                        ($status.proxy.health -in @('ready','rate-limited','key-unavailable')) -and
                        $status.tunnel.running -and $status.tunnel.ready
        if ($componentsUp) { break }
    } while ((Get-Date) -lt $deadline)

    $code = Get-ExitCodeForState $status.state
    $result = [pscustomobject]@{ action = $Action; status = $status; success = $code -eq 0 }
    if ($Json) {
        $result | ConvertTo-Json -Depth 6 -Compress
    } else {
        if ($status.state -eq 'ready') { Write-Output '[OK] Public API is ready.' }
        elseif ($status.state -eq 'waiting-upstream') { Write-Output '[OK] Public side is ready; waiting for Magpie upstream.' }
        else { Write-Output '[!] Public API is degraded; inspect logs and the component states below.' }
        Write-TextStatus $status
        Write-Output 'API key : see API-KEY.txt in this folder (local plaintext by design).'
    }
    exit $code
} catch {
    $message = $_.Exception.Message
    if ($Json) {
        [pscustomobject]@{ action = $Action; success = $false; error = $message } | ConvertTo-Json -Compress
    } else {
        Write-Error $message
    }
    if ($Action -in @('stop','restart')) { exit 2 }
    exit 1
}
