$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

$Julia = Get-Command julia -ErrorAction SilentlyContinue
if ($null -eq $Julia) {
    Write-Host "Julia was not found on PATH." -ForegroundColor Red
    Write-Host "Install Julia 1.10 or newer, then run this launcher again."
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "Starting IESA-Opt local UI at http://127.0.0.1:8123" -ForegroundColor Green
Write-Host "Keep this window open while using the browser UI."
& $Julia.Source --threads=auto --project="$RepoRoot" "scripts/serve_ui.jl"