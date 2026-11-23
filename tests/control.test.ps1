# Dependency-free integration tests. All processes/configuration live in temporary fixtures.
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'common.ps1')
$script:passed = 0
$script:failed = 0
$script:roots = New-Object 'System.Collections.Generic.List[string]'
$HostExe = (Get-Process -Id $PID).Path

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (actual=$Actual expected=$Expected)" }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Output "PASS $Name"
    } catch {
        $script:failed++
        Write-Output "FAIL $Name :: $($_.Exception.Message)"
    }
}
function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('magpie-control-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root, (Join-Path $root 'bin'), (Join-Path $root 'logs'), (Join-Path $root 'run') | Out-Null
    $script:roots.Add($root) | Out-Null
    return $root
}
function New-FreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}
function New-Fixture {
    $root = New-TestRoot
    foreach ($name in @('common.ps1', 'control.ps1', 'sync-key.ps1')) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $name) -Destination (Join-Path $root $name)
    }
    $proxyPort = New-FreePort
    $upstreamPort = New-FreePort
    $metricsPort = New-FreePort
    $cfg = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config.json') -Raw | ConvertFrom-Json
    $cfg.listenPort = $proxyPort
    $cfg.upstream = "http://127.0.0.1:$upstreamPort"
    $cfg.settingsPath = Join-Path $root 'settings.json'
    $cfg | Add-Member -NotePropertyName logPath -NotePropertyValue (Join-Path $root 'logs\proxy.log')
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    $yml = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config.yml') -Raw
    $yml = $yml.Replace('apimagpie.example.com', 'example.test')
    $yml = $yml.Replace('127.0.0.1:8790', "127.0.0.1:$proxyPort")
    $yml = $yml.Replace('127.0.0.1:20242', "127.0.0.1:$metricsPort")
    Set-Content -LiteralPath (Join-Path $root 'config.yml') -Value $yml -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'launch.vbs') -Value "' no-op test launcher" -Encoding ASCII
    return $root
}
function Import-ProjectFunction([string]$File, [string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot $File), [ref]$tokens, [ref]$errors)
    Assert-Equal @($errors).Count 0 "Parse $File"
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    Assert-True ($null -ne $fn) "Function $Name not found in $File"
    Invoke-Expression "function script:$Name $($fn.Body.Extent.Text)"
}
function Start-IdleNode([string]$Root) {
    $scriptPath = Join-Path $Root 'proxy.js'
    Set-Content -LiteralPath $scriptPath -Value 'setInterval(() => {}, 1000);' -Encoding ASCII
    $node = Find-MagpieNodeExe
    return Start-Process -FilePath $node -ArgumentList ('"{0}"' -f $scriptPath) -WorkingDirectory $Root -WindowStyle Hidden -PassThru
}
function Start-HealthNode([string]$Root, [int]$Code, [int]$Port) {
    $scriptPath = Join-Path $Root "health-$Code.js"
    $source = 'require("node:http").createServer((q,s)=>{s.writeHead(Number(process.argv[2]));s.end("x");}).listen(Number(process.argv[3]),"127.0.0.1");'
    Set-Content -LiteralPath $scriptPath -Value $source -Encoding ASCII
    $node = Find-MagpieNodeExe
    $p = Start-Process -FilePath $node -ArgumentList @($scriptPath, [string]$Code, [string]$Port) -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(5)
    while (-not (Test-MagpieTcp -HostName '127.0.0.1' -Port $Port -TimeoutMs 100)) {
        if ($p.HasExited -or (Get-Date) -gt $deadline) { throw "Health fixture $Code failed to listen" }
        Start-Sleep -Milliseconds 30
    }
    return $p
}

Test-Case 'every ingress forwarding service is validated and only final 404 fallback is exempt' {
    $root = New-Fixture
    $config = Get-MagpiePublicConfig -Root $root
    $valid = Get-MagpieTunnelConfig -Root $root
    Assert-MagpiePublicBinding -Config $config -Tunnel $valid
    Assert-Equal @($valid.Services).Count 1 'Default forwarding service count'

    $path = Join-Path $root 'config.yml'
    $base = Get-Content -LiteralPath $path -Raw
    $extra = "  - hostname: 'other.test'`n    service: http://127.0.0.1:3425`n"
    Set-Content -LiteralPath $path -Value $base.Replace('  - service: http_status:404', $extra + '  - service: http_status:404') -Encoding UTF8
    $blocked = Get-MagpieTunnelConfig -Root $root
    $threw = $false
    try { Assert-MagpiePublicBinding -Config $config -Tunnel $blocked } catch { $threw = $true }
    Assert-True $threw 'Second ingress bypassed binding validation'

    $extraValid = "  - hostname: 'other.test'`n    service: http://127.0.0.1:$($config.ListenPort)`n"
    Set-Content -LiteralPath $path -Value $base.Replace('  - service: http_status:404', $extraValid + '  - service: http_status:404') -Encoding UTF8
    $multiple = Get-MagpieTunnelConfig -Root $root
    Assert-Equal @($multiple.Services).Count 2 'Valid multiple forwarding services'
    Assert-MagpiePublicBinding -Config $config -Tunnel $multiple

    Set-Content -LiteralPath $path -Value ($base + "`nservice: http://127.0.0.1:3425`n") -Encoding UTF8
    $scoped = Get-MagpieTunnelConfig -Root $root
    Assert-Equal @($scoped.Services).Count 1 'Service outside ingress must not be collected'

    $badFallback = $base.Replace('  - service: http_status:404', '  - service: http_status:404' + "`n  - service: http://127.0.0.1:$($config.ListenPort)")
    Set-Content -LiteralPath $path -Value $badFallback -Encoding UTF8
    $threw = $false
    try { Get-MagpieTunnelConfig -Root $root } catch { $threw = $true }
    Assert-True $threw 'Non-final fallback was accepted'

    $unsupported = @(
        "  - hostname: 'quoted.test'`n    `"service`": http://198.51.100.8:80`n",
        "  - { hostname: 'flow.test', service: http://198.51.100.8:80 }`n",
        "  - hostname: 'missing-service.test'`n"
    )
    foreach ($rule in $unsupported) {
        Set-Content -LiteralPath $path -Value $base.Replace('  - service: http_status:404', $rule + '  - service: http_status:404') -Encoding UTF8
        $threw = $false
        try { Get-MagpieTunnelConfig -Root $root } catch { $threw = $true }
        Assert-True $threw "Unsupported ingress rule was accepted: $rule"
    }
}

Test-Case 'upstream path/query/userinfo/hash are rejected consistently' {
    foreach ($suffix in @('/base', '?token=x', '#fragment')) {
        $root = New-Fixture
        $path = Join-Path $root 'config.json'
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $cfg.upstream = "http://127.0.0.1:3425$suffix"
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        $threw = $false
        try { Get-MagpiePublicConfig -Root $root } catch { $threw = $true }
        Assert-True $threw "Invalid upstream accepted: $suffix"
    }
    $root = New-Fixture
    $path = Join-Path $root 'config.json'
    $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $cfg.upstream = 'http://user:pass@127.0.0.1:3425'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    $threw = $false
    try { Get-MagpiePublicConfig -Root $root } catch { $threw = $true }
    Assert-True $threw 'Upstream userinfo was accepted'
}

Test-Case 'PowerShell rejects lowercase methods and non-absolute route paths before startup' {
    foreach ($route in @(
        @{ path = '/v1/models'; methods = @('get') },
        @{ path = 'v1/models'; methods = @('GET') },
        @{ path = '/v1/models'; methods = 'GET' }
    )) {
        $root = New-Fixture
        $path = Join-Path $root 'config.json'
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $cfg.allowedRoutes = @($route)
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        $threw = $false
        try { Get-MagpiePublicConfig -Root $root } catch { $threw = $true }
        Assert-True $threw "Invalid route accepted: $($route | ConvertTo-Json -Compress)"
    }
    $root = New-Fixture
    $path = Join-Path $root 'config.json'
    $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $cfg.allowedRoutes = @{ path = '/v1/models'; methods = @('GET') }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    $threw = $false
    try { Get-MagpiePublicConfig -Root $root } catch { $threw = $true }
    Assert-True $threw 'Top-level allowedRoutes object was accepted'
}

Test-Case 'invalid numeric config values fail before startup' {
    $mutations = @(
        { param($c) $c.maxBodyBytes = 0 },
        { param($c) $c.maxBodyBytes = 'abc' },
        { param($c) $c.maxBodyBytes = 'NaN' },
        { param($c) $c.upstreamTimeoutMs = -1 },
        { param($c) $c.listenPort = 8790.5 },
        { param($c) $c.rateLimit.maxRequests = 'many' }
    )
    foreach ($mutate in $mutations) {
        $root = New-Fixture
        $path = Join-Path $root 'config.json'
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        & $mutate $cfg
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        $threw = $false
        try { Get-MagpiePublicConfig -Root $root } catch { $threw = $true }
        Assert-True $threw "Invalid numeric config accepted: $($cfg | ConvertTo-Json -Compress -Depth 10)"
    }
    $root = New-Fixture
    Assert-True ($null -ne (Get-MagpiePublicConfig -Root $root)) 'Valid config was rejected'
}

Test-Case 'Node lookup prefers PATH then standard and legacy fallbacks' {
    & {
        Import-ProjectFunction 'common.ps1' 'Find-MagpieNodeExe'
        function Get-Command { param($Name, $ErrorAction) return [pscustomobject]@{ Source = 'C:\path\node.exe' } }
        function Test-Path { return $false }
        Assert-Equal (Find-MagpieNodeExe) 'C:\path\node.exe' 'PATH priority'
    }
    & {
        Import-ProjectFunction 'common.ps1' 'Find-MagpieNodeExe'
        function Get-Command { return $null }
        function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -eq (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
        Assert-Equal (Find-MagpieNodeExe) (Join-Path $env:ProgramFiles 'nodejs\node.exe') 'Standard fallback'
    }
    & {
        Import-ProjectFunction 'common.ps1' 'Find-MagpieNodeExe'
        function Get-Command { return $null }
        function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -eq 'D:\Program Files\nodejs\node.exe' }
        Assert-Equal (Find-MagpieNodeExe) 'D:\Program Files\nodejs\node.exe' 'Legacy fallback'
    }
}

Test-Case 'all HTTP statuses are alive while readiness remains explicit' {
    $root = New-TestRoot
    foreach ($code in @(401, 429, 503, 404, 500)) {
        $port = New-FreePort
        $p = Start-HealthNode $root $code $port
        try {
            $health = Get-MagpieProxyHealth -Port $port -TimeoutMs 1000
            Assert-True $health.Alive "HTTP $code was not alive"
            Assert-Equal $health.Ready ($code -in @(401, 429)) "HTTP $code readiness"
            Assert-Equal $health.StatusCode $code "HTTP $code status"
        } finally {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $health = Get-MagpieProxyHealth -Port (New-FreePort) -TimeoutMs 200
    Assert-True (-not $health.Alive) 'Unreachable port was alive'
}

Test-Case 'IPv6 loopback TCP probe works on both PowerShell runtimes' {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::IPv6Loopback, 0)
    try {
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        Assert-True (Test-MagpieTcp -HostName '::1' -Port $port -TimeoutMs 500) 'IPv6 loopback was not reachable'
        Assert-True (-not (Test-MagpieTcp -HostName '127.0.0.1' -Port (New-FreePort) -TimeoutMs 200)) 'Unused IPv4 port was reachable'
    } finally {
        $listener.Stop()
    }
}

Test-Case 'foreign listener without owned components is degraded' {
    $root = New-Fixture
    $cfg = Get-MagpiePublicConfig -Root $root
    $port = $cfg.ListenPort
    $foreign = Start-HealthNode $root 404 $port
    try {
        Import-ProjectFunction 'control.ps1' 'Get-PublicStatus'
        $paths = @{ Root = $root; Config = $cfg; Tunnel = (Get-MagpieTunnelConfig -Root $root); ConfigError = $null }
        $status = Get-PublicStatus -Paths $paths
        Assert-Equal $status.state 'degraded' 'Foreign listener state'
        Assert-True $status.proxy.portOwnedByOther 'Foreign listener ownership flag'
    } finally {
        Stop-Process -Id $foreign.Id -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'stop with invalid config kills only exact owned fixtures and returns one result' {
    $root = New-Fixture
    $externalRoot = New-TestRoot
    $ownedProxy = Start-IdleNode $root
    $external = Start-IdleNode $externalRoot
    $ownedRun = Join-Path $root 'run.ps1'
    Set-Content -LiteralPath $ownedRun -Value 'Start-Sleep -Seconds 120' -Encoding ASCII
    $ownedSupervisor = Start-Process -FilePath $HostExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ownedRun)) -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath (Join-Path $root 'config.json') -Value '{broken json' -Encoding ASCII
    try {
        $output = & $HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'control.ps1') -Action stop -Json 2>&1
        $exit = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        $result = $text | ConvertFrom-Json
        Assert-Equal $exit 0 'Invalid-config stop exit'
        Assert-True $result.success 'Invalid-config stop success'
        Assert-True ([bool]$result.configError) 'Missing configError'
        Assert-Equal $result.status.state 'stopped' 'Invalid-config stop state'
        Assert-True $ownedProxy.HasExited 'Owned proxy survived'
        Assert-True $ownedSupervisor.HasExited 'Owned supervisor survived'
        Assert-True (-not $external.HasExited) 'External process was killed'
        $second = & $HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'control.ps1') -Action stop -Json 2>&1
        Assert-Equal $LASTEXITCODE 0 'Repeated invalid-config stop exit'
        Assert-True ((($second | Out-String).Trim() | ConvertFrom-Json).success) 'Repeated stop result'
    } finally {
        foreach ($p in @($ownedProxy, $ownedSupervisor, $external)) {
            if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

Test-Case 'restart JSON is one document even when startup is unsuccessful' {
    $root = New-Fixture
    $output = & $HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'control.ps1') -Action restart -Json -TimeoutSeconds 5 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    $result = $text | ConvertFrom-Json
    Assert-Equal $exit 1 "Unsuccessful restart exit: $text"
    Assert-Equal $result.action 'restart' 'Restart action'
    Assert-True ($result.PSObject.Properties.Name -contains 'stopped') 'Restart stopped field missing'
    Assert-True (-not $result.success) 'Degraded restart unexpectedly successful'
}

Test-Case 'PID write failures retain both returned child process objects' {
    & {
        $root = New-Fixture
        $LogDir = Join-Path $root 'logs'
        $PidDir = Join-Path $root 'run'
        $Here = $root
        $NodeExe = Find-MagpieNodeExe
        $ProxyJs = Join-Path $root 'proxy.js'
        $TunnelCfg = Join-Path $root 'config.yml'
        $CfExe = Join-Path $root 'bin\cloudflared.exe'
        New-Item -ItemType File -Force -Path $ProxyJs, $CfExe | Out-Null
        $Config = [pscustomobject]@{ ListenHost = '127.0.0.1' }
        $Port = 8790
        $metrics = '127.0.0.1:20242'
        $script:fakeChild = [pscustomobject]@{ Id = 424242 }
        function Write-Log($Message) {}
        function Reset-RedirectLogs($BaseName) {}
        function Test-CloudflaredHash { return $true }
        function Start-Process {
            param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
            return $script:fakeChild
        }
        function Set-Content {
            param($LiteralPath, $Encoding, $ErrorAction, [Parameter(ValueFromPipeline=$true)]$InputObject)
            process { throw 'injected PID write failure' }
        }
        Import-ProjectFunction 'run.ps1' 'Start-Proxy'
        Import-ProjectFunction 'run.ps1' 'Start-Tunnel'
        Assert-Equal (Start-Proxy).Id 424242 'Proxy object lost after PID failure'
        Assert-Equal (Start-Tunnel).Id 424242 'Tunnel object lost after PID failure'
    }
}

Test-Case 'cloudflared hash validation passes expected bytes and rejects drift' {
    & {
        $root = New-TestRoot
        $Here = $root
        $CfExe = Join-Path $root 'bin\cloudflared.exe'
        Set-Content -LiteralPath $CfExe -Value 'test-binary' -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath $CfExe -Algorithm SHA256).Hash
        Set-Content -LiteralPath (Join-Path $root 'bin\README.md') -Value ('SHA-256: `' + $hash + '`') -Encoding ASCII
        function Write-Log($Message) {}
        Import-ProjectFunction 'run.ps1' 'Test-CloudflaredHash'
        Assert-True (Test-CloudflaredHash) 'Expected hash rejected'
        Add-Content -LiteralPath $CfExe -Value 'drift' -Encoding ASCII
        Assert-True (-not (Test-CloudflaredHash)) 'Hash drift accepted'
    }
}

Test-Case 'sync-key refreshes metadata atomically, preserves unchanged mtime and removes stale output' {
    $root = New-Fixture
    $sync = Join-Path $root 'sync-key.ps1'
    $settings1 = Join-Path $root 'settings-one.json'
    $settings2 = Join-Path $root 'settings-two.json'
    Set-Content -LiteralPath $settings1 -Value '{"lanKey":"fake-test-key"}' -Encoding ASCII
    $cfg = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
    $cfg.settingsPath = $settings1
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    & $sync
    $out = Join-Path $root 'API-KEY.txt'
    Assert-True (Test-Path -LiteralPath $out) 'Key output missing'
    $firstTime = (Get-Item -LiteralPath $out).LastWriteTimeUtc
    & $sync
    Assert-Equal (Get-Item -LiteralPath $out).LastWriteTimeUtc $firstTime 'Unchanged output rewritten'

    $ymlPath = Join-Path $root 'config.yml'
    Set-Content -LiteralPath $ymlPath -Value ((Get-Content -LiteralPath $ymlPath -Raw).Replace('example.test', 'changed.test')) -Encoding UTF8
    & $sync
    Assert-True ((Get-Content -LiteralPath $out -Raw).Contains('# Endpoint : https://changed.test/v1')) 'Endpoint stayed stale'
    Set-Content -LiteralPath $settings2 -Value '{"lanKey":"fake-test-key"}' -Encoding ASCII
    $cfg.settingsPath = $settings2
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    & $sync
    Assert-True ((Get-Content -LiteralPath $out -Raw).Contains($settings2)) 'Source stayed stale'
    Assert-Equal @((Get-ChildItem -LiteralPath $root -Filter 'API-KEY.txt.*.tmp')).Count 0 'Atomic temp file leaked'

    Set-Content -LiteralPath $settings2 -Value '{"lanKey":""}' -Encoding ASCII
    & $sync
    Assert-True (-not (Test-Path -LiteralPath $out)) 'Empty key left stale output'
    Set-Content -LiteralPath $settings2 -Value '{"lanKey":"fake-test-key"}' -Encoding ASCII
    & $sync
    Remove-Item -LiteralPath $settings2 -Force
    & $sync
    Assert-True (-not (Test-Path -LiteralPath $out)) 'Missing settings left stale output'
}

Test-Case 'Get-ExitCode handles zero, nonzero, null and property errors' {
    & {
        Import-ProjectFunction 'run.ps1' 'Get-ExitCode'
        $zero = [pscustomobject]@{ ExitCode = 0 }
        $zero | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $true }
        Assert-Equal (Get-ExitCode $zero) 'code 0' 'Zero exit code'
        $nonzero = [pscustomobject]@{ ExitCode = 7 }
        $nonzero | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $true }
        Assert-Equal (Get-ExitCode $nonzero) 'code 7' 'Nonzero exit code'
        $nullCode = [pscustomobject]@{ ExitCode = $null }
        $nullCode | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) throw 'wait failed' }
        Assert-Equal (Get-ExitCode $nullCode) 'exit code unavailable' 'Null exit code'
        $broken = [pscustomobject]@{}
        $broken | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $false }
        $broken | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { throw 'no exit code' }
        Assert-Equal (Get-ExitCode $broken) 'exit code unavailable' 'Exceptional exit code'
    }
}

try {
    foreach ($root in $script:roots) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch {}
Write-Output "CONTROL_TEST_SUMMARY passed=$script:passed failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
