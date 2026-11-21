# Removes Agent Lid Closed for Windows: quits the app (restoring sleep), removes every hook it
# added, puts back the wake-timer setting it changed, and deletes the app and its login item.
# Your log and settings in %LOCALAPPDATA%\AgentLidClosed are kept unless you pass -RemoveData.
# If anything can't be undone, the app files stay (the hooks still use them) and it says so;
# run it again once the problem is fixed.
param([switch]$RemoveData)
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'Programs\AgentLidClosed'
$state = Join-Path $env:LOCALAPPDATA 'AgentLidClosed'
$exe = Join-Path $target 'AgentLidClosed.exe'

# Checked before anything changes: without the active plan, a restored value might not take effect.
$activeScheme = ([regex]'[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Match((powercfg /getactivescheme) -join ' ').Value.ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or -not $activeScheme) {
    Write-Warning '使用中の電源プランを読み取れなかったため、何も変更していません。もう一度実行してください'
    exit 1
}

if (Test-Path $exe) { & $exe quit | Out-Null }
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Process AgentLidClosed -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
Get-Process AgentLidClosed -ErrorAction SilentlyContinue | Stop-Process -Force

function Set-PowerSetting([string]$scheme, [string]$sub, [string]$setting, $ac, $dc) {
    powercfg /setacvalueindex $scheme $sub $setting $ac; $ok = $LASTEXITCODE -eq 0
    powercfg /setdcvalueindex $scheme $sub $setting $dc; $ok = $ok -and $LASTEXITCODE -eq 0
    if ($scheme.ToLowerInvariant() -eq $activeScheme) { powercfg /setactive $scheme; $ok = $ok -and $LASTEXITCODE -eq 0 }
    return $ok
}
$failed = $false

# A lid action still changed because the app was killed.
$holdFile = Join-Path $state 'power-hold.json'
if (Test-Path $holdFile) {
    $saved = Get-Content -Raw $holdFile | ConvertFrom-Json
    if (Set-PowerSetting $saved.scheme '4f971e89-eebd-4455-a8de-9e59040e7347' '5ca83367-6e45-459f-a27b-476b1d01c936' $saved.ac $saved.dc) {
        Remove-Item -Force $holdFile
    } else {
        $failed = $true
        Write-Warning '蓋を閉じたときの動作を元に戻せませんでした'
    }
}

# Wake timers, per power plan the installer changed. Entries that fail stay for the next run.
$wakeFile = Join-Path $state 'wake-timers-original.json'
if (Test-Path $wakeFile) {
    $json = Get-Content -Raw $wakeFile | ConvertFrom-Json
    $entries = @{}
    if ($json.scheme) { $entries[$json.scheme] = $json }
    else { foreach ($p in $json.PSObject.Properties) { $entries[$p.Name] = $p.Value } }
    $left = @{}
    foreach ($scheme in @($entries.Keys)) {
        $e = $entries[$scheme]
        if (-not (Set-PowerSetting $scheme '238c9fa8-0aad-41ed-83f4-97be242c8f20' 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d' $e.ac $e.dc)) {
            $left[$scheme] = @{ ac = $e.ac; dc = $e.dc }
        }
    }
    if ($left.Count) {
        $failed = $true
        Set-Content -Path "$wakeFile.tmp" -Encoding ASCII -Value ($left | ConvertTo-Json -Compress)
        [IO.File]::Replace("$wakeFile.tmp", $wakeFile, [NullString]::Value)
        Write-Warning 'スリープ解除タイマーの設定を一部元に戻せませんでした'
    } else {
        Remove-Item -Force $wakeFile
    }
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$script = Join-Path $target 'agent-lid.mjs'
if (-not (Test-Path $script)) { $script = Join-Path $PSScriptRoot 'agent-lid.mjs' }
if ($node) {
    & $node $script hooks uninstall
    if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Warning 'いくつかのフックを削除できませんでした' }
} else {
    $failed = $true
    Write-Warning 'Node.js が見つからないため、フックは削除していません'
}

if ($failed) {
    Write-Warning "アプリのファイルは残しました（$target）。問題を直してから、もう一度 uninstall.ps1 を実行してください"
    exit 1
}
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Startup')) 'Agent Lid Closed.lnk')
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $target
if ($RemoveData) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $state }
Write-Host 'Agent Lid Closed を削除しました。T3 Code の自動再開の設定はそのまま残ります。'
