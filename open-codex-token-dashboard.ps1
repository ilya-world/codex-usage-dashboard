Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$refresh = Join-Path $root "refresh-codex-token-usage.ps1"
$dashboard = Join-Path $root "codex-token-dashboard.html"

& $refresh | Out-Host
Start-Process $dashboard
