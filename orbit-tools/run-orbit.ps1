#Requires -Version 5.1
<#
.SYNOPSIS
  Run Orbit Atom phase SQL in order (operator / CI — not for end-user clients).

.EXAMPLE
  .\run-orbit.ps1 -Phase 3
  .\run-orbit.ps1 -Phase all -IncludeDevSeed
  .\run-orbit.ps1 -Phase 1 -IncludeSweep -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', 'all')]
    [string] $Phase = '3',

    [switch] $IncludeDevSeed,
    [switch] $IncludeSweep,
    [switch] $IncludePreflight,
    [switch] $IncludeVerify,
    [switch] $DryRun,

    [string] $DocumentsRoot = (Split-Path $PSScriptRoot -Parent),
    [string] $EnvFile = (Join-Path $PSScriptRoot '.env')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-OrbitEnv {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $name = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Get-OrbitManifest {
    $manifestPath = Join-Path $PSScriptRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Missing manifest: $manifestPath"
    }
    Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Test-StepIncluded {
    param($Step)
    if (-not $Step.optional) { return $true }
    if ($Step.destructive -and $IncludeSweep) { return $true }
    if ($Step.file -eq '03_dev_seed_optional.sql' -and $IncludeDevSeed) { return $true }
    if ($Step.file -eq '01_preflight_checks.sql' -and $IncludePreflight) { return $true }
    if ($Step.file -eq 'PHASE1_VERIFY.sql' -and $IncludeVerify) { return $true }
    return $false
}

function Invoke-OrbitSqlFile {
    param(
        [string] $FullPath,
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $FullPath)) {
        throw "SQL file not found: $FullPath"
    }

    Write-Host ""
    Write-Host "==> $Label" -ForegroundColor Cyan
    Write-Host "    $FullPath" -ForegroundColor DarkGray

    if ($DryRun) {
        Write-Host "    [dry-run] skipped" -ForegroundColor Yellow
        return
    }

    $dbUrl = $env:ORBIT_DATABASE_URL
    $useCli = $env:ORBIT_USE_SUPABASE_CLI -eq '1'

    if ($dbUrl) {
        $psql = Get-Command psql -ErrorAction SilentlyContinue
        if (-not $psql) {
            throw "psql not found on PATH. Install PostgreSQL client tools or set ORBIT_USE_SUPABASE_CLI=1 with Supabase CLI linked."
        }
        & $psql.Source $dbUrl '-v' 'ON_ERROR_STOP=1' '-f' $FullPath
        if ($LASTEXITCODE -ne 0) {
            throw "psql failed (exit $LASTEXITCODE) for $FullPath"
        }
        return
    }

    if ($useCli) {
        $supabase = Get-Command supabase -ErrorAction SilentlyContinue
        if (-not $supabase) {
            throw "Supabase CLI not found. Install: https://supabase.com/docs/guides/cli"
        }
        & $supabase.Source 'db' 'execute' '-f' $FullPath
        if ($LASTEXITCODE -ne 0) {
            throw "supabase db execute failed (exit $LASTEXITCODE) for $FullPath"
        }
        return
    }

    throw @"
No database connection configured.
  - Set ORBIT_DATABASE_URL in orbit-tools/.env (copy from .env.example), or
  - Run: supabase link --project-ref YOUR_REF
  - Then set ORBIT_USE_SUPABASE_CLI=1 in .env

End-user apps must NOT run these scripts. Use CI or a trusted operator machine only.
"@
}

Import-OrbitEnv -Path $EnvFile
$manifest = Get-OrbitManifest

$phaseKeys = if ($Phase -eq 'all') { @('1', '2', '3') } else { @($Phase) }

Write-Host "Orbit deploy runner" -ForegroundColor Green
Write-Host "  Phases: $($phaseKeys -join ', ')"
Write-Host "  Root:   $DocumentsRoot"
if ($DryRun) { Write-Host "  Mode:   DRY RUN" -ForegroundColor Yellow }

$ran = 0
$skipped = 0

foreach ($key in $phaseKeys) {
    $phase = $manifest.phases.$key
    if (-not $phase) { throw "Unknown phase key in manifest: $key" }

    Write-Host ""
    Write-Host "######## Phase $key — $($phase.label) ########" -ForegroundColor Green

    foreach ($step in $phase.steps) {
        if (-not (Test-StepIncluded -Step $step)) {
            $skipped++
            Write-Host "    [skip optional] $($step.file)" -ForegroundColor DarkYellow
            continue
        }

        $dir = Join-Path $DocumentsRoot $phase.dir
        $fullPath = Join-Path $dir $step.file
        $label = "Phase $key / $($step.file)"
        Invoke-OrbitSqlFile -FullPath $fullPath -Label $label
        $ran++
    }
}

Write-Host ""
Write-Host "Done. Executed: $ran file(s). Skipped optional: $skipped." -ForegroundColor Green
if ($DryRun) {
    Write-Host "Re-run without -DryRun to apply." -ForegroundColor Yellow
}
