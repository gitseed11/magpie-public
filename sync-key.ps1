# Sync Magpie's lanKey into a human-readable file.
#
# This is NOT a hardcoded copy: every run re-reads settings.json and only
# rewrites the output when the key, endpoint or source metadata changes.
#
# Called periodically by run.ps1's supervisor loop; can also be run by hand:
#   powershell -ExecutionPolicy Bypass -File .\sync-key.ps1

param(
    # Empty means: use config.json's settingsPath, then the standard user path.
    [string]$SettingsPath = '',
    [string]$OutDir       = $PSScriptRoot
)

$outFile = [IO.Path]::GetFullPath((Join-Path $OutDir 'API-KEY.txt'))
$configPath = Join-Path $OutDir 'config.json'
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    try {
        $proxyCfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($proxyCfg.settingsPath) {
            $SettingsPath = [Environment]::ExpandEnvironmentVariables([string]$proxyCfg.settingsPath)
        }
    } catch {}
}
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $env:USERPROFILE '.config\magpie\settings.json'
}

# Public endpoint is read from config.yml (single source of truth) so this
# script stays correct if the folder is copied to another machine/domain. The
# literal below is only the fallback for a tree without a readable config.yml.
$endpoint = 'https://apimagpie.example.com/v1'
$cfgYml = Join-Path $OutDir 'config.yml'
if (Test-Path -LiteralPath $cfgYml) {
    try {
        # Same anchored pattern as common.ps1 Get-Scalar 'hostname'.
        $m = [regex]::Match(
            (Get-Content -LiteralPath $cfgYml -Raw),
            '(?m)^\s*(?:-\s*)?hostname\s*:\s*(?:"([^"]+)"|''([^'']+)''|([^#\r\n]+))'
        )
        if ($m.Success) {
            $publicHost = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) |
                    Where-Object { $_ } | Select-Object -First 1
            if ($publicHost) { $endpoint = 'https://' + $publicHost.Trim() + '/v1' }
        }
    } catch {}
}

try {
    $cfg = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $key = if ($cfg.lanKey) { $cfg.lanKey.Trim() } else { '' }
} catch {
    # Never leave a stale credential copy behind when its source is unavailable.
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction Stop }
    return
}

if ([string]::IsNullOrWhiteSpace($key)) {
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction Stop }
    return
}

# Ignore only the timestamp. The key, endpoint and source together define the
# current content; the first non-comment line remains prefix-agnostic.
$endpointLine = "# Endpoint : $endpoint"
$sourceLine = "# Source   : lanKey field in $SettingsPath"
$changed = $true
if (Test-Path -LiteralPath $outFile) {
    $old = Get-Content -LiteralPath $outFile -Raw -ErrorAction Stop
    $oldLines = $old -split "`r?`n"
    $oldKey = $oldLines | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
    $oldEndpoint = $oldLines | Where-Object { $_.StartsWith('# Endpoint : ') } | Select-Object -First 1
    $oldSource = $oldLines | Where-Object { $_.StartsWith('# Source   : ') } | Select-Object -First 1
    if ($oldKey -and $oldKey.Trim() -ceq $key -and $oldEndpoint -ceq $endpointLine -and $oldSource -ceq $sourceLine) {
        $changed = $false
    }
}

if ($changed) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $lines = @(
        '# Magpie public API key (auto-synced, do not edit by hand)',
        '#',
        $endpointLine,
        $sourceLine,
        "# Updated  : $stamp",
        '#',
        '# Usage:',
        "#   curl $endpoint/models -H `"Authorization: Bearer <key below>`"",
        '#',
        $key
    )
    $tempFile = "$outFile.$PID.tmp"
    try {
        # ASCII keeps this readable no matter which PowerShell version runs it.
        Set-Content -LiteralPath $tempFile -Value $lines -Encoding ASCII -ErrorAction Stop
        if (Test-Path -LiteralPath $outFile) {
            [IO.File]::Replace($tempFile, $outFile, [NullString]::Value)
        } else {
            [IO.File]::Move($tempFile, $outFile)
        }
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
