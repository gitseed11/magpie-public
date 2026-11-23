# Shared, dependency-free helpers for run.ps1, control.ps1 and the local panel.
# This file has no side effects; callers explicitly dot-source it.

function Get-MagpieUriHost {
    param([Parameter(Mandatory=$true)][uri]$Uri)
    $ip = $null
    if ([Net.IPAddress]::TryParse($Uri.DnsSafeHost, [ref]$ip)) {
        if ([Net.IPAddress]::Loopback.Equals($ip)) { return '127.0.0.1' }
        if ([Net.IPAddress]::IPv6Loopback.Equals($ip)) { return '::1' }
    }
    return $Uri.DnsSafeHost
}

function Get-MagpiePublicConfig {
    param([Parameter(Mandatory=$true)][string]$Root)

    $raw = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($raw.listenHost -notin @('127.0.0.1', '::1')) {
        throw 'config.json listenHost must be 127.0.0.1 or ::1.'
    }
    $port = [int]$raw.listenPort
    if ($port -lt 1 -or $port -gt 65535) { throw 'config.json listenPort is invalid.' }

    $upstream = [uri][string]$raw.upstream
    if ($upstream.Scheme -notin @('http', 'https') -or (Get-MagpieUriHost $upstream) -notin @('127.0.0.1', '::1')) {
        throw 'config.json upstream must be HTTP(S) on an explicit loopback address.'
    }
    if (-not $raw.allowedRoutes -or $raw.allowedRoutes.Count -eq 0) {
        throw 'config.json allowedRoutes must be a non-empty array.'
    }
    foreach ($route in $raw.allowedRoutes) {
        if (-not $route.path -or -not $route.methods -or $route.methods.Count -eq 0) {
            throw 'Each allowed route requires path and methods.'
        }
    }

    $settingsPath = [string]$raw.settingsPath
    if ([string]::IsNullOrWhiteSpace($settingsPath)) {
        $settingsPath = Join-Path $env:USERPROFILE '.config\magpie\settings.json'
    }
    $settingsPath = [Environment]::ExpandEnvironmentVariables($settingsPath)

    return [pscustomobject]@{
        Raw          = $raw
        ListenHost   = [string]$raw.listenHost
        ListenPort   = $port
        Upstream     = $upstream
        UpstreamPort = $upstream.Port
        SettingsPath = $settingsPath
    }
}

function Get-MagpieTunnelConfig {
    param([Parameter(Mandatory=$true)][string]$Root)

    $text = Get-Content -LiteralPath (Join-Path $Root 'config.yml') -Raw -ErrorAction Stop
    function Get-Scalar([string]$Name) {
        $pattern = '(?m)^\s*(?:-\s*)?' + [regex]::Escape($Name) + '\s*:\s*(?:"([^"]+)"|''([^'']+)''|([^#\r\n]+))'
        $m = [regex]::Match($text, $pattern)
        if (-not $m.Success) { return '' }
        foreach ($i in 1..3) {
            if ($m.Groups[$i].Success -and $m.Groups[$i].Value) { return $m.Groups[$i].Value.Trim() }
        }
        return ''
    }

    $metrics = Get-Scalar 'metrics'
    if (-not $metrics) { $metrics = '127.0.0.1:20242' }
    $metricsUri = [uri]('http://' + $metrics)
    if ((Get-MagpieUriHost $metricsUri) -notin @('127.0.0.1', '::1')) {
        throw 'config.yml metrics must use an explicit loopback address.'
    }

    $service = Get-Scalar 'service'
    $serviceUri = [uri]$service
    if ($serviceUri.Scheme -ne 'http' -or (Get-MagpieUriHost $serviceUri) -notin @('127.0.0.1', '::1')) {
        throw 'config.yml ingress service must be HTTP on an explicit loopback address.'
    }
    $hostname = Get-Scalar 'hostname'
    if (-not $hostname) { throw 'config.yml has no public hostname.' }

    return [pscustomobject]@{
        TunnelId         = Get-Scalar 'tunnel'
        CredentialsFile = Get-Scalar 'credentials-file'
        MetricsAddress   = $metrics
        MetricsPort      = $metricsUri.Port
        Service          = $serviceUri
        Hostname         = $hostname
        PublicEndpoint   = 'https://' + $hostname + '/v1'
    }
}

function Find-MagpieNodeExe {
    $found = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $standard = Join-Path $env:ProgramFiles 'nodejs\node.exe'
    if (Test-Path -LiteralPath $standard -PathType Leaf) { return $standard }
    return ''
}

function Format-MagpieHost {
    param([Parameter(Mandatory=$true)][string]$HostName)
    if ($HostName -eq '::1') { return '[::1]' }
    return $HostName
}

function Assert-MagpiePublicBinding {
    param($Config, $Tunnel)
    if (
        (Get-MagpieUriHost $Tunnel.Service) -ne $Config.ListenHost -or
        $Tunnel.Service.Port -ne $Config.ListenPort -or
        $Tunnel.Service.AbsolutePath -ne '/' -or
        $Tunnel.Service.Query -or
        $Tunnel.Service.UserInfo
    ) {
        throw 'config.yml ingress service must exactly target the configured proxy listener, with no path/query/user info.'
    }
}

function Test-MagpieOwnedProcess {
    param(
        [Parameter(Mandatory=$true)]$Process,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][ValidateSet('supervisor','proxy','tunnel')][string]$Role
    )

    $cmd = [string]$Process.CommandLine
    if (-not $cmd) { return $false }
    $name = [string]$Process.Name

    if ($Role -eq 'supervisor') {
        if ($name -notin @('powershell.exe','pwsh.exe')) { return $false }
        $target = [regex]::Escape((Join-Path $Root 'run.ps1'))
        return [regex]::IsMatch($cmd, '(?:^|\s)-File\s+"?' + $target + '"?(?:\s|$)', 'IgnoreCase')
    }
    if ($Role -eq 'proxy') {
        if ($name -ne 'node.exe') { return $false }
        $target = [regex]::Escape((Join-Path $Root 'proxy.js'))
        # proxy.js must be the first script argument, not merely text in node -e.
        $node = '(?:"[^"]*node\.exe"|\S*node\.exe)'
        return [regex]::IsMatch($cmd, '^\s*' + $node + '\s+"?' + $target + '"?(?:\s|$)', 'IgnoreCase')
    }

    if ($name -ne 'cloudflared.exe') { return $false }
    $target = [regex]::Escape((Join-Path $Root 'config.yml'))
    $configMatches = [regex]::IsMatch($cmd, '(?:^|\s)--config\s+"?' + $target + '"?(?:\s|$)', 'IgnoreCase')
    if (-not $configMatches) { return $false }
    # The project binary can be used manually with another config. Executable
    # path alone is therefore insufficient; require this exact config as well.
    $expectedExe = Join-Path $Root 'bin\cloudflared.exe'
    $actualExe = [string]$Process.ExecutablePath
    return (-not $actualExe) -or [string]::Equals($actualExe, $expectedExe, 'OrdinalIgnoreCase')
}

function Get-MagpieOwnedProcesses {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [ValidateSet('supervisor','proxy','tunnel')][string]$Role
    )
    $roles = if ($Role) { @($Role) } else { @('supervisor','proxy','tunnel') }
    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}

    # PID files narrow the first pass, but are never trusted without path checks.
    foreach ($r in $roles) {
        $pidPath = Join-Path $Root ('run\' + $(if ($r -eq 'supervisor') { 'supervisor' } elseif ($r -eq 'proxy') { 'proxy' } else { 'cloudflared' }) + '.pid')
        if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
            $saved = (Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
            $savedId = 0
            if ([int]::TryParse([string]$saved, [ref]$savedId) -and $savedId -gt 0) {
                $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $savedId) -ErrorAction SilentlyContinue
                if ($p -and (Test-MagpieOwnedProcess -Process $p -Root $Root -Role $r)) {
                    $p | Add-Member -NotePropertyName MagpieRole -NotePropertyValue $r
                    $result.Add($p) | Out-Null
                    $seen[[string]$p.ProcessId] = $true
                }
            }
        }
    }

    # Exact-path enumeration also finds orphans whose PID file is stale/missing.
    $names = @('powershell.exe','pwsh.exe','node.exe','cloudflared.exe')
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $names })) {
        if ($seen.ContainsKey([string]$p.ProcessId)) { continue }
        foreach ($r in $roles) {
            if (Test-MagpieOwnedProcess -Process $p -Root $Root -Role $r) {
                $p | Add-Member -NotePropertyName MagpieRole -NotePropertyValue $r
                $result.Add($p) | Out-Null
                $seen[[string]$p.ProcessId] = $true
                break
            }
        }
    }
    return $result.ToArray()
}

function Test-MagpiePortListening {
    param([Parameter(Mandatory=$true)][int]$Port)
    try {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
    } catch {
        return $false
    }
}

function Test-MagpieTcp {
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Get-MagpieProxyHealth {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$HostName = '127.0.0.1',
        [int]$TimeoutMs = 5000
    )
    $state = 'unreachable'
    $alive = $false
    $ready = $false
    $code = 0
    $response = $null
    try {
        $requestHost = Format-MagpieHost $HostName
        $req = [Net.HttpWebRequest]::Create("http://${requestHost}:$Port/v1/models")
        $req.Method = 'GET'
        $req.KeepAlive = $false
        $req.Proxy = $null
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $false
        $req.Headers.Add('Authorization', 'Bearer definitely-not-the-key')
        $req.UserAgent = 'magpie-public-supervisor-healthcheck'
        try { $response = $req.GetResponse() } catch [Net.WebException] {
            $response = $_.Exception.Response
        }
        if ($response) {
            $code = [int]$response.StatusCode
            switch ($code) {
                401 { $state = 'ready'; $alive = $true; $ready = $true }
                429 { $state = 'rate-limited'; $alive = $true; $ready = $true }
                503 { $state = 'key-unavailable'; $alive = $true; $ready = $false }
                default { $state = 'unexpected-' + $code }
            }
        }
    } catch {
        $state = 'unreachable'
    } finally {
        if ($response) { try { $response.Close() } catch {} }
    }
    return [pscustomobject]@{
        Alive      = $alive
        Ready      = $ready
        State      = $state
        StatusCode = $code
    }
}

function Test-MagpieTunnelReady {
    param(
        [Parameter(Mandatory=$true)][string]$MetricsAddress,
        [int]$TimeoutMs = 5000
    )
    $response = $null
    try {
        $req = [Net.HttpWebRequest]::Create("http://$MetricsAddress/ready")
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null
        $response = $req.GetResponse()
        return [int]$response.StatusCode -eq 200
    } catch {
        return $false
    } finally {
        if ($response) { try { $response.Close() } catch {} }
    }
}
