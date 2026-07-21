Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$taskName = "CodexTokenUsageSnapshotRefresh"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    "Removed scheduled task: $taskName"
}
else {
    "Scheduled task is not installed: $taskName"
}
