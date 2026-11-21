# Installs Agent Lid Closed for Windows, like scripts/install.sh on macOS:
#  1. Builds AgentLidClosed.exe and installs the app in %LOCALAPPDATA%\Programs\AgentLidClosed.
#  2. Adds hooks for the tools it finds (Claude Code settings.json, Codex hooks.json).
#  3. Enables T3 Code's native auto-resume unless you turned it off.
#  4. Allows wake timers in the active power plan (for waking before usage resets).
#  5. Starts the app now and at login.
# No administrator rights are needed. Re-running updates everything and keeps your settings.
param(
    [string[]]$ClaudeConfigDir = @(),
    [switch]$Codex,
    [switch]$NoClaude,
    [switch]$NoCodex,
    [switch]$NoWakeTimers,
    [switch]$NoStartAtLogin
)
$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'Programs\AgentLidClosed'
$state = Join-Path $env:LOCALAPPDATA 'AgentLidClosed'
$guid = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'Node.js 22.16 以降が必要です: https://nodejs.org' }
$version = [version]((& $node --version).TrimStart('v'))
if ($version -lt [version]'22.16.0') { throw "Node.js 22.16 以降が必要です（今は $version）" }

Write-Host '実行中のアプリを終了しています…'
$exe = Join-Path $target 'AgentLidClosed.exe'
if (Test-Path $exe) { & $exe quit | Out-Null }
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Process AgentLidClosed -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
Get-Process AgentLidClosed -ErrorAction SilentlyContinue | Stop-Process -Force
# The first Windows version ran from a PowerShell tray script.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='node.exe'" |
    Where-Object { $_.CommandLine -match 'agent-lid-closed\\windows\\(tray\.ps1|agent-lid\.mjs)' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "インストール先: $target"
New-Item -ItemType Directory -Force -Path (Join-Path $target 'lib') | Out-Null
Copy-Item (Join-Path $source 'agent-lid.mjs'), (Join-Path $source 'agent-lid-hook.mjs') $target -Force
Copy-Item (Join-Path $source 'lib\*.mjs') (Join-Path $target 'lib') -Force
& (Join-Path $source 'build.ps1') -Output $exe
Set-Content -Path (Join-Path $target 'node-path.txt') -Value $node -Encoding ASCII

Write-Host 'フックを追加しています…'
$hookArgs = @('hooks', 'install')
if ($NoClaude) { $hookArgs += '--no-claude' }
if ($NoCodex) { $hookArgs += '--no-codex' }
if ($Codex) { $hookArgs += '--codex' }
foreach ($dir in $ClaudeConfigDir) { $hookArgs += @('--claude-config-dir', $dir) }
& $node (Join-Path $target 'agent-lid.mjs') @hookArgs
if ($LASTEXITCODE -ne 0) { Write-Warning 'いくつかの設定ファイルにはフックを追加できませんでした（上のメッセージを参照）' }
# Keeps an explicit opt-out in T3 Code, as the macOS installer does.
& $node (Join-Path $target 'agent-lid.mjs') set auto-resume on --preserve 2>$null | Out-Null

if (-not $NoWakeTimers) {
    # "Allow wake timers" (SUB_SLEEP / RTCWAKE) = Enable for AC and battery. The previous values
    # are saved per power plan before any change, so uninstall.ps1 can put each plan back.
    $sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; $setting = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'
    $scheme = ([regex]$guid).Match((powercfg /getactivescheme) -join ' ').Value.ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) { $scheme = '' }
    $values = @()
    if ($scheme) {
        $values = [regex]::Matches((powercfg /qh $scheme $sub $setting) -join "`n", '0x([0-9a-fA-F]{8})')
        if ($LASTEXITCODE -ne 0) { $values = @() }
    }
    $savedFile = Join-Path $state 'wake-timers-original.json'
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $saved = @{}
    if (Test-Path $savedFile) {
        $json = Get-Content -Raw $savedFile | ConvertFrom-Json
        if ($json.scheme) { $saved[$json.scheme] = @{ ac = $json.ac; dc = $json.dc } }
        else { foreach ($p in $json.PSObject.Properties) { $saved[$p.Name] = @{ ac = $p.Value.ac; dc = $p.Value.dc } } }
    }
    if (-not $scheme -or $values.Count -lt 2) {
        Write-Warning 'スリープ解除タイマーの設定を読み取れなかったため、変更していません'
    } else {
        if (-not $saved.ContainsKey($scheme)) {
            $saved[$scheme] = @{
                ac = [Convert]::ToInt32($values[$values.Count - 2].Groups[1].Value, 16)
                dc = [Convert]::ToInt32($values[$values.Count - 1].Groups[1].Value, 16)
            }
            # Written beside the journal, then swapped in, so an interruption can't lose other plans' values.
            Set-Content -Path "$savedFile.tmp" -Encoding ASCII -Value ($saved | ConvertTo-Json -Compress)
            if (Test-Path $savedFile) { [IO.File]::Replace("$savedFile.tmp", $savedFile, [NullString]::Value) }
            else { [IO.File]::Move("$savedFile.tmp", $savedFile) }
        }
        powercfg /setacvalueindex $scheme $sub $setting 1; $ok = $LASTEXITCODE -eq 0
        powercfg /setdcvalueindex $scheme $sub $setting 1; $ok = $ok -and $LASTEXITCODE -eq 0
        powercfg /setactive $scheme; $ok = $ok -and $LASTEXITCODE -eq 0
        if ($ok) { Write-Host '電源プランでスリープ解除タイマーを許可しました' }
        else { Write-Warning 'スリープ解除タイマーを許可できませんでした。電源オプションで「スリープ解除タイマーの許可」を有効にしてください' }
    }
}

$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Agent Lid Closed.lnk'
if (-not $NoStartAtLogin) {
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $target
    $link.Description = 'Agent Lid Closed'
    $link.Save()
}

Start-Process -FilePath $exe -WorkingDirectory $target
Write-Host ''
Write-Host 'Agent Lid Closed を起動しました。通知領域のアイコンから操作できます。'
Write-Host '開いている Claude Code のセッションは再起動してください。Codex では /hooks で新しいフックを信頼してください。'
