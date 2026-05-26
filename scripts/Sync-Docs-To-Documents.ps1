# Push docs + updated READMEs from orbit-systems repo to Documents working copies.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$DocsRoot = Split-Path $RepoRoot -Parent

$docFiles = @(
    @{ Src = 'docs\FIELD_TRIP_15_10_PROTOCOL.md'; Dst = 'orbit-systems\docs\FIELD_TRIP_15_10_PROTOCOL.md' },
    @{ Src = 'docs\COMPLIANCE_REGISTRY.md'; Dst = 'orbit-systems\docs\COMPLIANCE_REGISTRY.md' },
    @{ Src = 'orbit-phase3\ORBIT_PHASE3_README.md'; Dst = 'orbit-phase3\ORBIT_PHASE3_README.md' },
    @{ Src = 'README.md'; Dst = 'orbit-systems\README.md' },
    @{ Src = 'STACK.md'; Dst = 'orbit-systems\STACK.md' }
)

foreach ($item in $docFiles) {
    $src = Join-Path $RepoRoot $item.Src
    $dst = Join-Path $DocsRoot $item.Dst
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Skip (missing): $src"
        continue
    }
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }
    if ((Resolve-Path $src).Path -eq (Resolve-Path $dst -ErrorAction SilentlyContinue).Path) {
        Write-Host "Skip (same file): $($item.Dst)"
        continue
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "Copied -> $($item.Dst)"
}

Write-Host "Done."
