param(
    [switch]$NoOpen
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This installer currently supports Windows only."
}

$root = $PSScriptRoot
$codexHome = Join-Path $env:USERPROFILE ".codex"
$taskInstaller = Join-Path $root "install-codex-token-usage-refresh-task.ps1"
$dashboard = Join-Path $root "codex-token-dashboard.html"
$snapshot = Join-Path $root "data\codex-token-usage-data.js"

if (-not (Test-Path -LiteralPath $codexHome)) {
    throw "Codex data directory was not found at '$codexHome'. Run Codex at least once, then retry."
}

New-Item -ItemType Directory -Path (Join-Path $root "data") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root "logs") -Force | Out-Null

& $taskInstaller | Out-Host

if (-not (Test-Path -LiteralPath $snapshot)) {
    throw "The initial local snapshot was not created."
}

Write-Host ""
Write-Host "Codex Usage Dashboard is installed."
Write-Host "Data stays on this computer and refreshes every hour."
Write-Host "Dashboard: $dashboard"

if (-not $NoOpen) {
    Start-Process $dashboard
}
