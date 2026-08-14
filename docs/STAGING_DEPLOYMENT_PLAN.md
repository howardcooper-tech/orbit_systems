# Orbit Systems — staging deployment plan

**Production is out of scope.** Do not link, push, reset, or execute SQL against any project except staging.

| Item | Value |
|------|--------|
| Environment | Staging only |
| Project URL | `https://ydlwukjzqtssbzirnefs.supabase.co` |
| Project ref | `ydlwukjzqtssbzirnefs` |
| Canonical SQL | `orbit-phase1/`, `orbit-phase2/`, `orbit-phase3/` via `orbit-tools/manifest.json` |
| Do not use | `supabase db push` for a greenfield staging DB |
| Do not use | `supabase db reset` |
| Do not use | `-IncludeSweep` on first apply |

---

## Why not `supabase db push`

`supabase/migrations/` contains **only** later overlays:

| File in `supabase/migrations/` | What it is |
|--------------------------------|------------|
| `phase_3b_lockdown.sql` | PIN hash + `verify_student_pin` |
| `phase_3c_duval_wall.sql` | Duval Wall / WORM |
| `phase_3d_transit_mode.sql` | Transit Mode |
| `20260814000000_phase_3e_auth_tenant_jwt_hook.sql` | JWT `tenant_id` hook |

Phase 1–3 core tables and Phase 3 `01`–`07` live **only** under `orbit-phase*`. Pushing migrations alone will fail (missing tables) or leave an incomplete schema.

`orbit-tools/run-orbit.ps1` is the deploy runner: it executes manifest files in order with `psql` (`ORBIT_DATABASE_URL`) or `supabase db execute` (`ORBIT_USE_SUPABASE_CLI=1`).

Phase 3b is **not** in `manifest.json`. Apply it once between Phase 3 `07` and `08`.

---

## Migration order (empty staging)

Skip optional/destructive files on first apply.

```text
Phase 1  orbit-phase1/01_extensions.sql
      →  02_infrastructure.sql
      →  03_students_sis.sql
      →  04_fleet.sql
      →  05_trips.sql
      →  06_bay_comms.sql
      →  07_mesh_iot.sql
      →  08_emergency.sql
      →  09_field_routes.sql
      →  10_halo_alerts.sql
      →  11_archive_schema.sql
      →  12_indexes.sql
      →  PHASE1_VERIFY.sql          (optional, read-only)

Phase 2  orbit-phase2/01_preflight_checks.sql   (optional, read-only)
      →  02_sis_import_helpers.sql
      →  03_dev_seed_optional.sql    (optional; skip unless you want seed data)

Phase 3  orbit-phase3/01_core_functions.sql
      →  02_enable_rls.sql
      →  03_rls_duval_wall.sql
      →  04_audit_triggers.sql
      →  05_telemetry_immutable.sql
      →  06_updated_at_triggers.sql
      →  07_business_gates.sql

Phase 3b supabase/migrations/phase_3b_lockdown.sql
         (not in the runner — SQL Editor or one-off execute)

Phase 3c orbit-phase3/08_phase_3c_duval_wall.sql

Phase 3d orbit-phase3/09_transit_mode.sql

Phase 3e orbit-phase3/10_auth_tenant_jwt_hook.sql
```

Do **not** run `orbit-phase1/00_sweep_reset_staging.sql` (`-IncludeSweep`). It is destructive.

---

## Files that exist only outside `supabase/migrations`

All of `orbit-phase1/*`, `orbit-phase2/*`, and `orbit-phase3/01`–`07`. Those must be applied via the runner (or SQL Editor in the same order). Do not copy them into `supabase/migrations/` as part of this staging connect.

Duplicates (same content, two paths):

- `08_phase_3c_duval_wall.sql` ↔ `supabase/migrations/phase_3c_duval_wall.sql`
- `09_transit_mode.sql` ↔ `supabase/migrations/phase_3d_transit_mode.sql`
- `10_auth_tenant_jwt_hook.sql` ↔ `supabase/migrations/20260814000000_phase_3e_auth_tenant_jwt_hook.sql`

Use the `orbit-phase3/` copies when using the runner.

---

## Operator commands (do not run until this plan is approved)

From the Documents / `orbit_systems` repo root.

```powershell
# 1. Confirm config points at staging
Get-Content supabase\config.toml | Select-String "project_id"

# 2. Login (once)
supabase login

# 3. Link CLI to STAGING only
supabase link --project-ref ydlwukjzqtssbzirnefs

# 4. Local secret (gitignored). Staging DB URI from
#    Staging Dashboard → Project Settings → Database → URI
#    postgres role. Never production.
copy orbit-tools\.env.example orbit-tools\.env
# Edit orbit-tools\.env — set ORBIT_DATABASE_URL to the STAGING URI.

# 5. Preview only
.\orbit-tools\run-orbit.ps1 -Phase all -IncludeVerify -DryRun

# 6. After approval: apply (no sweep)
.\orbit-tools\run-orbit.ps1 -Phase all -IncludeVerify

# 7. Phase 3b (not in the runner)
supabase db execute -f supabase/migrations/phase_3b_lockdown.sql
# or paste that file into Staging SQL Editor as postgres.

# 8. If step 6 was run when 08–10 were already in the Phase 3 manifest,
#    3c–3e applied in step 6. If 3b was skipped until step 7, re-run:
.\orbit-tools\run-orbit.ps1 -Phase 3 -DryRun
```

If the runner already executed `08`–`10` before 3b, apply 3b afterward (`IF NOT EXISTS` / `CREATE OR REPLACE` is safe). Prefer 3b **before** 3c on a greenfield DB: run Phase 1–2, Phase 3 files `01`–`07` only is **not** how the current manifest works (Phase 3 always includes `08`–`10`).

**Greenfield workaround:** either

- run `.\orbit-tools\run-orbit.ps1 -Phase all -IncludeVerify` then execute `phase_3b_lockdown.sql`, or
- apply 1–2, then SQL Editor `01`–`07`, then 3b, then `08`–`10`.

Recommended for staging empty project: **runner Phase all (no sweep), then 3b file.** 3b only adds `students.pin_hash` and `verify_student_pin`; it does not need to precede 3c for RLS.

### Commands that must not be run

```text
supabase db reset
supabase db push
supabase functions deploy
.\orbit-tools\run-orbit.ps1 -IncludeSweep
```

---

## Dashboard steps (staging project only)

Confirm the URL is `https://ydlwukjzqtssbzirnefs.supabase.co`.

1. After 3e SQL: **Authentication → Hooks → Custom Access Token** → enable `public.custom_access_token_hook`. See `docs/AUTH_TENANT_HOOK_DEPLOY.md`.
2. Create at least one staff user and a `staff_profiles` row with `district_id` before expecting RLS reads.
3. Auth → URL config: add Lovable / local origins when wiring UI (not required to apply SQL).

Do not enable the hook on production from this plan.

---

## Edge Functions

`supabase/functions/telemetry-ingress/index.ts` is **not** part of the SQL runner.

Do **not** deploy it in this pass. Known defect: it inserts `position` while `bus_telemetry_logs` uses `location`. Fix before `supabase functions deploy --project-ref ydlwukjzqtssbzirnefs`.

---

## Validation (staging SQL Editor, postgres)

```sql
SELECT current_database();

SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public', 'archive')
ORDER BY 1, 2;

SELECT proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND proname IN (
    'get_my_role', 'get_my_district', 'jwt_tenant_id',
    'verify_student_pin', 'custom_access_token_hook',
    'resolve_orbit_tenant_id'
  )
ORDER BY 1;

SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND relkind = 'r'
ORDER BY 1;
```

Then run `supabase/AUTH_TENANT_HOOK_VALIDATE.sql` (read-only) and `docs/AUTH_TENANT_HOOK_TEST_PLAN.md` after the Dashboard hook is on.

---

## Rollback

Staging only:

1. Dashboard → disable Custom Access Token hook.
2. Do **not** drop Phase 1–3c objects as a rollback; restore from a staging backup / new empty staging project if the apply is wrong.
3. Never point rollback or restore at production.

---

## Safety

- This document targets **only** `ydlwukjzqtssbzirnefs`.
- Production project refs and URLs must not be used with these commands.
- `orbit-tools/.env` stays gitignored. No service-role keys in git.
