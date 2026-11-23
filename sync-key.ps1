# Sync Magpie's lanKey into a human-readable file.
#
# This is NOT a hardcoded copy: every run re-reads settings.json and only
# rewrites the output when the key actually changes.
#
# Called periodically by run.ps1's supervisor loop; can also be run by hand:
#   powershell -ExecutionPolicy Bypass -File .\sync-key.ps1

param(
    # Empty means: use config.json's settingsPath, then the standard user path.
    [string]$SettingsPath = '',
    [string]$OutDir       = $PSScriptRoot
)

$outFile = Join-Path $OutDir 'API-KEY.txt'
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
# script stays correct if the folder is copied to another machine/domain.
$endpoint = 'https://apimagpie.example.com/v1'
$cfgYml = Join-Path $OutDir 'config.yml'
if (Test-Path -LiteralPath $cfgYml) {
    try {
        $m = [regex]::Match(
            (Get-Content -LiteralPath $cfgYml -Raw),
            'hostname:\s*(?:"([^"]+)"|''([^'']+)''|([^\s#]+))'
        )
        if ($m.Success) {
            $publicHost = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) |
                    Where-Object { $_ } | Select-Object -First 1
            if ($publicHost) { $endpoint = 'https://' + $publicHost + '/v1' }
        }
    } catch {}
}

try {
    $cfg = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $key = if ($cfg.lanKey) { $cfg.lanKey.Trim() } else { '' }
} catch {
    # settings.json may be mid-rewrite by Magpie; try again next cycle.
    return
}

if ([string]::IsNullOrWhiteSpace($key)) { return }

# Only rewrite when the key changed (ignore the timestamp and comment lines).
# Take the first non-comment, non-empty line so this also works if Magpie ever
# generates a key with a different prefix than "sk-magpie".
$changed = $true
if (Test-Path -LiteralPath $outFile) {
    $old = Get-Content -LiteralPath $outFile -Raw
    $oldKey = ($old -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1)
    if ($oldKey -and $oldKey.Trim() -eq $key) { $changed = $false }
}

if ($changed) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = @(
        '# Magpie public API key (auto-synced, do not edit by hand)',
        '#',
        "# Endpoint : $endpoint",
        "# Source   : lanKey field in $SettingsPath",
        "# Updated  : $stamp",
        '#',
        '# Usage:',
        "#   curl $endpoint/models -H `"Authorization: Bearer <key below>`"",
        '#',
        $key
    )
    # ASCII keeps this readable no matter which PowerShell version runs it.
    Set-Content -LiteralPath $outFile -Value $lines -Encoding ASCII
}
