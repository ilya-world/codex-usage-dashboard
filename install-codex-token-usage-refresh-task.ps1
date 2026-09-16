Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$refreshScript = Join-Path $root "refresh-codex-token-usage.ps1"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$powershell = if ($pwshCommand -and $pwshCommand.Source) { [string]$pwshCommand.Source } else { $windowsPowerShell }
$taskName = "CodexTokenUsageSnapshotRefresh"
$runnerDirectory = Join-Path $env:LOCALAPPDATA "CodexUsageDashboard"
$runnerScript = Join-Path $runnerDirectory "refresh-runner.ps1"
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$now = Get-Date
$firstRun = $now.Date.AddHours($now.Hour + 1)

# Some Windows policies block Task Scheduler from opening scripts in Documents.
# Keep the scheduled entry point in LocalAppData and delegate to this installation.
[System.IO.Directory]::CreateDirectory($runnerDirectory) | Out-Null
$escapedRefreshScript = $refreshScript.Replace("'", "''")
$runnerContent = @"
Set-StrictMode -Version 2.0
`$ErrorActionPreference = "Stop"

& '$escapedRefreshScript'
"@
[System.IO.File]::WriteAllText(
    $runnerScript,
    $runnerContent,
    [System.Text.UTF8Encoding]::new($false)
)

$action = New-ScheduledTaskAction `
    -Execute $powershell `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`"" `
    -WorkingDirectory $root

$hourlyTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At $firstRun `
    -RepetitionInterval (New-TimeSpan -Hours 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentIdentity

$principal = New-ScheduledTaskPrincipal `
    -UserId $currentIdentity `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($hourlyTrigger, $logonTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description "Refreshes the Codex token usage dashboard data snapshot every hour." `
    -Force | Out-Null

& $refreshScript | Out-Host

"Installed scheduled task: $taskName"
"PowerShell host: $powershell"
"Scheduled task runner: $runnerScript"
"First scheduled hourly refresh: $($firstRun.ToString('yyyy-MM-dd HH:mm:ss'))"
