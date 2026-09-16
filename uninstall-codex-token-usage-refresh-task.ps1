Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$taskName = "CodexTokenUsageSnapshotRefresh"
$runnerDirectory = Join-Path $env:LOCALAPPDATA "CodexUsageDashboard"
$runnerScript = Join-Path $runnerDirectory "refresh-runner.ps1"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    "Removed scheduled task: $taskName"
}
else {
    "Scheduled task is not installed: $taskName"
}

if (Test-Path -LiteralPath $runnerScript) {
    Remove-Item -LiteralPath $runnerScript -Force
    "Removed scheduled task runner: $runnerScript"
}

if ((Test-Path -LiteralPath $runnerDirectory) -and
    -not (Get-ChildItem -LiteralPath $runnerDirectory -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $runnerDirectory -Force
}
