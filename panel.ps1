# Local-only desktop control panel. No HTTP listener, no web framework, and no
# automatic start/stop on open/close. Requires only Windows PowerShell + WinForms.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Control = Join-Path $Here 'control.ps1'

function Start-ControlProcess([string]$Action) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Control + '" -Action ' + $Action + ' -Json'
    $psi.WorkingDirectory = $Here
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        $process.Dispose()
        throw 'Could not start control.ps1.'
    }
    return $process
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Magpie 公网 API'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object Drawing.Size(600, 390)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object Windows.Forms.Label
$title.Text = 'Magpie 公网 API'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(22, 18)
$form.Controls.Add($title)

$overall = New-Object Windows.Forms.Label
$overall.Text = '正在读取状态…'
$overall.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$overall.ForeColor = [Drawing.Color]::DarkOrange
$overall.AutoSize = $true
$overall.Location = New-Object Drawing.Point(25, 62)
$form.Controls.Add($overall)

$stateLabels = @{}
$rows = @(
    @('watchdog', 'Watchdog'),
    @('proxy', '认证代理'),
    @('tunnel', 'Cloudflare Tunnel'),
    @('magpie', 'Magpie 上游（独立）')
)
$y = 105
foreach ($row in $rows) {
    $name = New-Object Windows.Forms.Label
    $name.Text = $row[1]
    $name.AutoSize = $false
    $name.Size = New-Object Drawing.Size(190, 25)
    $name.Location = New-Object Drawing.Point(28, $y)
    $form.Controls.Add($name)

    $value = New-Object Windows.Forms.Label
    $value.Text = '—'
    $value.AutoSize = $false
    $value.Size = New-Object Drawing.Size(350, 25)
    $value.Location = New-Object Drawing.Point(220, $y)
    $form.Controls.Add($value)
    $stateLabels[$row[0]] = $value
    $y += 34
}

$endpoint = New-Object Windows.Forms.Label
$endpoint.Text = ''
$endpoint.AutoSize = $false
$endpoint.Size = New-Object Drawing.Size(540, 24)
$endpoint.Location = New-Object Drawing.Point(28, 244)
$form.Controls.Add($endpoint)

$startButton = New-Object Windows.Forms.Button
$startButton.Text = '启动'
$startButton.Size = New-Object Drawing.Size(90, 34)
$startButton.Location = New-Object Drawing.Point(28, 284)
$form.Controls.Add($startButton)

$stopButton = New-Object Windows.Forms.Button
$stopButton.Text = '停止'
$stopButton.Size = New-Object Drawing.Size(90, 34)
$stopButton.Location = New-Object Drawing.Point(128, 284)
$form.Controls.Add($stopButton)

$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = '刷新'
$refreshButton.Size = New-Object Drawing.Size(90, 34)
$refreshButton.Location = New-Object Drawing.Point(228, 284)
$form.Controls.Add($refreshButton)

$copyButton = New-Object Windows.Forms.Button
$copyButton.Text = '复制公网地址'
$copyButton.Size = New-Object Drawing.Size(125, 34)
$copyButton.Location = New-Object Drawing.Point(348, 284)
$form.Controls.Add($copyButton)

$logsButton = New-Object Windows.Forms.Button
$logsButton.Text = '日志'
$logsButton.Size = New-Object Drawing.Size(90, 34)
$logsButton.Location = New-Object Drawing.Point(483, 284)
$form.Controls.Add($logsButton)

$note = New-Object Windows.Forms.Label
$note.Text = '停止只关闭代理、隧道和看门狗；不会停止 Magpie。关闭窗口不会主动启停服务；进行中的操作请先等待完成。'
$note.AutoSize = $false
$note.Size = New-Object Drawing.Size(545, 42)
$note.ForeColor = [Drawing.Color]::DimGray
$note.Location = New-Object Drawing.Point(28, 334)
$form.Controls.Add($note)

function Update-Status($Status) {
    if (-not $Status) { return }
    $script:lastEndpoint = [string]$Status.endpoint
    $endpoint.Text = $script:lastEndpoint

    switch ([string]$Status.state) {
        'ready' { $overall.Text = '状态：已就绪'; $overall.ForeColor = [Drawing.Color]::ForestGreen }
        'waiting-upstream' { $overall.Text = '状态：公网侧已就绪，等待 Magpie'; $overall.ForeColor = [Drawing.Color]::DarkOrange }
        'stopped' { $overall.Text = '状态：已停止'; $overall.ForeColor = [Drawing.Color]::DimGray }
        default { $overall.Text = '状态：降级 / 需要检查'; $overall.ForeColor = [Drawing.Color]::Firebrick }
    }

    $stateLabels.watchdog.Text = if ($Status.watchdog.running) { '运行中' } else { '已停止' }
    $proxyText = if ($Status.proxy.running) { '运行中 · ' + $Status.proxy.health } else { '已停止' }
    if ($Status.proxy.portOwnedByOther) { $proxyText += ' · 端口被其他程序占用' }
    $stateLabels.proxy.Text = $proxyText
    $tunnelText = if ($Status.tunnel.running) { if ($Status.tunnel.ready) { '运行中 · 已连接' } else { '运行中 · 未就绪' } } else { '已停止' }
    if ($Status.tunnel.portOwnedByOther) { $tunnelText += ' · metrics 端口冲突' }
    $stateLabels.tunnel.Text = $tunnelText
    $stateLabels.magpie.Text = if ($Status.magpie.reachable) { '端口可连接 · 不受本面板启停控制' } else { '不可连接 · 公网请求将返回 502' }

    foreach ($key in @('watchdog','proxy','tunnel','magpie')) {
        $running = switch ($key) {
            'watchdog' { $Status.watchdog.running }
            'proxy' { $Status.proxy.running }
            'tunnel' { $Status.tunnel.running }
            'magpie' { $Status.magpie.reachable }
        }
        $stateLabels[$key].ForeColor = if ($running) { [Drawing.Color]::ForestGreen } else { [Drawing.Color]::DimGray }
    }
    if ($Status.proxy.health -eq 'key-unavailable') { $stateLabels.proxy.ForeColor = [Drawing.Color]::Firebrick }
    if ($Status.tunnel.running -and -not $Status.tunnel.ready) { $stateLabels.tunnel.ForeColor = [Drawing.Color]::DarkOrange }
}

$script:actionProcess = $null
$script:actionName = ''
$script:stdoutTask = $null
$script:stderrTask = $null
$script:actionStartedAt = [datetime]::MinValue
$script:actionTimeoutSeconds = 75

# The BackgroundWorker callback path did not complete reliably in this panel
# on Windows PowerShell 5.1. Avoid depending on a worker-thread runspace:
# start the helper on the UI thread and poll HasExited with a WinForms timer.
# No PowerShell code runs on a background thread, and the UI never WaitForExit().
$actionTimer = New-Object Windows.Forms.Timer
$actionTimer.Interval = 250

function Complete-ControlAction {
    if (-not $script:actionProcess) { $actionTimer.Stop(); return }
    $process = $script:actionProcess
    $action = $script:actionName
    $timedOut = (([datetime]::UtcNow - $script:actionStartedAt).TotalSeconds -gt $script:actionTimeoutSeconds)
    $probeError = $null
    try {
        if ($timedOut -and -not $process.HasExited) { $process.Kill() }
        if (-not $process.HasExited) { return }
        if (-not $timedOut -and (($script:stdoutTask -and -not $script:stdoutTask.IsCompleted) -or
                ($script:stderrTask -and -not $script:stderrTask.IsCompleted))) { return }
    } catch {
        $probeError = $_.Exception.Message
    }

    $actionTimer.Stop()
    try {
        if ($probeError) { throw $probeError }
        if ($timedOut) { throw "control.ps1 timed out after $script:actionTimeoutSeconds seconds." }
        $stdout = if ($script:stdoutTask) { $script:stdoutTask.GetAwaiter().GetResult().Trim() } else { '' }
        $stderr = if ($script:stderrTask) { $script:stderrTask.GetAwaiter().GetResult().Trim() } else { '' }
        $exitCode = $process.ExitCode
        $data = $null
        if ($stdout) {
            try { $data = $stdout | ConvertFrom-Json } catch { $data = $null }
        }
        if ($data -and $data.error) { throw [string]$data.error }
        if (-not $data) {
            if ($stderr) { throw $stderr }
            throw "control.ps1 returned no usable status (exit $exitCode)."
        }
        $status = if ($action -eq 'status') { $data } else { $data.status }
        if (-not $status) { throw 'control.ps1 returned no component status.' }
        Update-Status $status
        if ($data.configError) {
            $overall.Text = '状态：已停止；配置需修复'
            $overall.ForeColor = [Drawing.Color]::DarkOrange
        }
        if ($action -eq 'stop' -and $data.PSObject.Properties.Name -contains 'success' -and -not $data.success) {
            throw 'Stop completed with owned processes still running.'
        }
    } catch {
        if (-not $form.IsDisposed) {
            $overall.ForeColor = [Drawing.Color]::Firebrick
            if ($action -eq 'status') {
                # The 15 s auto-refresh must never open a modal dialog: a broken
                # config would otherwise block the UI every 15 seconds. Show the
                # reason inline and keep the last known component state.
                $overall.Text = '状态：读取失败'
                $endpoint.Text = [string]$_.Exception.Message
            } else {
                $overall.Text = '状态：操作失败'
                [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Magpie 控制面板', 'OK', 'Error') | Out-Null
            }
        }
    } finally {
        try { $process.Dispose() } catch {}
        $script:actionProcess = $null
        $script:stdoutTask = $null
        $script:stderrTask = $null
        if (-not $form.IsDisposed) {
            $startButton.Enabled = $true
            $stopButton.Enabled = $true
            $refreshButton.Enabled = $true
        }
    }
}
$actionTimer.Add_Tick({ Complete-ControlAction })

function Start-ControlAction([string]$Action) {
    if ($script:actionProcess) { return }
    $startButton.Enabled = $false
    $stopButton.Enabled = $false
    $refreshButton.Enabled = $false
    $overall.Text = $(if ($Action -eq 'start') { '正在启动…' } elseif ($Action -eq 'stop') { '正在停止…' } else { '正在刷新…' })
    try {
        $script:actionName = $Action
        $script:actionStartedAt = [datetime]::UtcNow
        $script:actionProcess = Start-ControlProcess $Action
        # .NET performs pipe reads without running PowerShell on another thread.
        $script:stdoutTask = $script:actionProcess.StandardOutput.ReadToEndAsync()
        $script:stderrTask = $script:actionProcess.StandardError.ReadToEndAsync()
        $actionTimer.Start()
    } catch {
        if ($script:actionProcess) {
            try { if (-not $script:actionProcess.HasExited) { $script:actionProcess.Kill() } } catch {}
            try { $script:actionProcess.Dispose() } catch {}
        }
        $script:actionProcess = $null
        $script:stdoutTask = $null
        $script:stderrTask = $null
        $startButton.Enabled = $true
        $stopButton.Enabled = $true
        $refreshButton.Enabled = $true
        $overall.ForeColor = [Drawing.Color]::Firebrick
        if ($Action -eq 'status') {
            # Same rule as the completion path: the 15 s auto-refresh never
            # opens a modal dialog, even when the helper cannot start at all.
            $overall.Text = '状态：读取失败'
            $endpoint.Text = [string]$_.Exception.Message
        } else {
            $overall.Text = '状态：操作失败'
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Magpie 控制面板', 'OK', 'Error') | Out-Null
        }
    }
}

$startButton.Add_Click({ Start-ControlAction 'start' })
$stopButton.Add_Click({
    $answer = [Windows.Forms.MessageBox]::Show("停止公网代理、隧道和看门狗？`n`nMagpie 本身不会停止。", '确认停止', 'YesNo', 'Question')
    if ($answer -eq 'Yes') { Start-ControlAction 'stop' }
})
$refreshButton.Add_Click({ Start-ControlAction 'status' })
$copyButton.Add_Click({ if ($script:lastEndpoint) { [Windows.Forms.Clipboard]::SetText($script:lastEndpoint) } })
$logsButton.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Join-Path $Here 'logs')) | Out-Null })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick({ if (-not $script:actionProcess) { Start-ControlAction 'status' } })
$timer.Start()
$form.Add_Shown({ Start-ControlAction 'status' })
$form.Add_FormClosing({ $timer.Stop(); $actionTimer.Stop() })
[void]$form.ShowDialog()
$timer.Dispose()
$actionTimer.Dispose()
if ($script:actionProcess) {
    try { if (-not $script:actionProcess.HasExited) { $script:actionProcess.Kill() } } catch {}
    $script:actionProcess.Dispose()
    $script:actionProcess = $null
}
