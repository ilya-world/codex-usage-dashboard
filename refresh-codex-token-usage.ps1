Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$exporter = Join-Path $root "tools\export-codex-token-usage.ps1"
$logDir = Join-Path $root "logs"
$logPath = Join-Path $logDir "codex-token-usage-refresh.log"

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Write-RefreshLog {
    param([string]$Message)

    $timestamp = (Get-Date).ToString("s")
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value "[$timestamp] $Message"
}

Write-RefreshLog "Starting Codex token usage snapshot refresh."

$mutex = New-Object System.Threading.Mutex($false, "Local\CodexTokenUsageSnapshotRefresh")
$lockTaken = $false

try {
    try {
        $lockTaken = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $lockTaken = $true
    }

    if (-not $lockTaken) {
        Write-RefreshLog "Skipped: another Codex token usage refresh is already running."
        return
    }

    $result = & $exporter 2>&1

    foreach ($line in $result) {
        Write-RefreshLog ([string]$line)
    }

    Write-RefreshLog "Codex token usage snapshot refresh completed."
} catch {
    Write-RefreshLog ("Codex token usage snapshot refresh failed: {0}" -f $_.Exception.Message)
    throw
} finally {
    if ($lockTaken) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
