# Copy Orbit SQL + deploy tools from Documents working tree into this repo.
# Run from: orbit-systems\  with parent folder containing orbit-phase1, etc.

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$SourceRoot = Split-Path $RepoRoot -Parent

$folders = @('orbit-phase1', 'orbit-phase2', 'orbit-phase3', 'orbit-tools')
$files = @('ORBIT_ATOM_AUDIT.md', 'ORBIT_ATOM_SPEC_REMEDIATION.sql')

Write-Host "Repo:   $RepoRoot"
Write-Host "Source: $SourceRoot"
Write-Host ""

foreach ($name in $folders) {
    $src = Join-Path $SourceRoot $name
    $dst = Join-Path $RepoRoot $name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Skip (missing): $src"
        continue
    }
    if (Test-Path -LiteralPath $dst) {
        Remove-Item -LiteralPath $dst -Recurse -Force
    }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    Write-Host "Copied $name"
}

foreach ($name in $files) {
    $src = Join-Path $SourceRoot $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $RepoRoot $name) -Force
        Write-Host "Copied $name"
    }
}

Write-Host ""
Write-Host "Done. Review git status, then commit and push."
