# Orbit deploy runner (operator / CI)

Runs Phase 1–3 SQL **in order** from your machine or CI pipeline. District clients (mobile/web) **cannot and should not** run these — Postgres DDL/RLS requires privileged credentials.

## Architecture

```
[Operator laptop or GitHub Actions]
        │
        │  ORBIT_DATABASE_URL (secret)  OR  Supabase CLI (linked project)
        ▼
[Supabase Postgres]  ← same SQL as SQL Editor, automated
```

- **Not** Supabase JS client (`supabase.from(...)`) — that cannot execute migration files.
- **Not** end-user JWT — `authenticated` cannot `ALTER TABLE` / create policies.

## One-time setup

1. Install **PostgreSQL client** (`psql`) *or* [Supabase CLI](https://supabase.com/docs/guides/cli).
2. Copy `.env.example` → `.env` in this folder (add `.env` to `.gitignore` if you use git).
3. Set `ORBIT_DATABASE_URL` from Supabase → **Project Settings → Database → Connection string (URI)**. Use the **postgres** role password (migrations), not the anon key.

Optional CLI mode instead of URL:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

In `.env`:

```
ORBIT_USE_SUPABASE_CLI=1
```

## Commands (Windows PowerShell)

From `Documents\orbit-tools`:

```powershell
# Preview what would run (Phase 3 only — where you are now)
.\run-orbit.ps1 -Phase 3 -DryRun

# Run Phase 3 (01 → 07)
.\run-orbit.ps1 -Phase 3

# Full stack (skip destructive/optional unless flags set)
.\run-orbit.ps1 -Phase all

# Staging: wipe + schema + dev seed + brain
.\run-orbit.ps1 -Phase all -IncludeSweep -IncludeDevSeed -IncludeVerify
```

Flags:

| Flag | Effect |
|------|--------|
| `-DryRun` | List files only |
| `-IncludeDevSeed` | Runs `orbit-phase2/03_dev_seed_optional.sql` |
| `-IncludeSweep` | Runs `orbit-phase1/00_sweep_reset_staging.sql` (**destructive**) |
| `-IncludePreflight` | Runs phase 2 read-only preflight |
| `-IncludeVerify` | Runs `PHASE1_VERIFY.sql` after phase 1 |

## Bash (CI / macOS / WSL)

```bash
chmod +x run-orbit.sh
DRY_RUN=1 ./run-orbit.sh 3          # preview
./run-orbit.sh 3                    # run phase 3
INCLUDE_DEV_SEED=1 ./run-orbit.sh all
```

## GitHub Actions (example)

Store `ORBIT_DATABASE_URL` as a repo secret. Job runs on `ubuntu-latest` with `postgresql-client` installed; invoke `run-orbit.sh` with `DRY_RUN=0`.

## Security

- Keep `.env` and database URLs out of the app repo clients ship.
- Service role in mobile apps bypasses RLS — never embed for migrations; use dedicated CI secret.
- Re-running scripts is mostly idempotent (`DROP IF EXISTS`, `CREATE OR REPLACE`), but `-IncludeSweep` deletes data.

## Manifest

File order lives in `manifest.json`. Edit there when you add `08_*.sql` etc., then re-run the runner.
