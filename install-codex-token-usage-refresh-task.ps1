Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$refreshScript = Join-Path $root "refresh-codex-token-usage.ps1"
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$taskName = "CodexTokenUsageSnapshotRefresh"
$now = Get-Date
$firstRun = $now.Date.AddHours($now.Hour + 1)

$action = New-ScheduledTaskAction `
    -Execute $powershell `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$refreshScript`"" `
    -WorkingDirectory $root

$hourlyTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At $firstRun `
    -RepetitionInterval (New-TimeSpan -Hours 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($hourlyTrigger, $logonTrigger) `
    -Settings $settings `
    -Description "Refreshes the Codex token usage dashboard data snapshot every hour." `
    -Force | Out-Null

& $refreshScript | Out-Host

"Installed scheduled task: $taskName"
"First scheduled hourly refresh: $($firstRun.ToString('yyyy-MM-dd HH:mm:ss'))"
