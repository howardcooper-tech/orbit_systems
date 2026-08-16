# Orbit Systems — staging deployment plan

**Production is out of scope.** Do not link, push, reset, or execute SQL against any project except staging. Never point staging configuration at the production project.

| Item | Value |
|------|--------|
| Environment | Staging only |
| Project URL | `https://ydlwukjzqtssbzirnefs.supabase.co` |
| Project ref | `ydlwukjzqtssbzirnefs` |
| Canonical deploy | `orbit-tools/run-orbit.ps1` + `orbit-tools/manifest.json` |
| Canonical SQL | `orbit-phase1/`, `orbit-phase2/`, `orbit-phase3/`, plus Phase 3b via the runner |
| Do not use | `supabase db push` for this greenfield bootstrap |
| Do not use | `supabase db reset` |
| Do not use | `-IncludeSweep` on first apply |
| Do not deploy | `telemetry-ingress` during this database bootstrap |

---

## Why not `supabase db push`

`supabase/migrations/` contains **only** later overlays:

| File in `supabase/migrations/` | What it is |
|--------------------------------|------------|
| `phase_3b_lockdown.sql` | PIN hash + `verify_student_pin` (applied by the runner, not by `db push`) |
| `phase_3c_duval_wall.sql` | Duval Wall / WORM |
| `phase_3d_transit_mode.sql` | Transit Mode |
| `20260814000000_phase_3e_auth_tenant_jwt_hook.sql` | JWT `tenant_id` hook |

Phase 1–3 core tables and Phase 3 `01`–`07` live **only** under `orbit-phase*`. Pushing migrations alone will fail (missing tables) or leave an incomplete schema.

`orbit-tools/run-orbit.ps1` is the deploy runner. It executes manifest files in order with `psql` (`ORBIT_DATABASE_URL`) or `supabase db execute` (`ORBIT_USE_SUPABASE_CLI=1`).

Phase 3b is **in** `manifest.json` and is executed automatically by `orbit-tools/run-orbit.ps1`. It is **not** a separate manual SQL step. The manifest step is:

```json
{ "file": "phase_3b_lockdown.sql", "path": "supabase/migrations/phase_3b_lockdown.sql" }
```

That `path` is repository-relative. The runner resolves it from the repo root and applies it between Phase 3 `07_business_gates.sql` and `08_phase_3c_duval_wall.sql`. Do not run `supabase db execute -f supabase/migrations/phase_3b_lockdown.sql` as a one-off.

---

## Canonical greenfield sequence

Staging bootstrap must follow this exact order. `-Phase all` on the runner applies it in one pass (skipping optional/destructive files unless their flags are set):

```text
Phase 1
→ Phase 2
→ Phase 3 01–07
→ Phase 3b
→ Phase 3c
→ Phase 3d
→ Phase 3e
```

## Migration order (empty staging)

Skip optional/destructive files on first apply. Do **not** pass `-IncludeSweep`.

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
      →  PHASE1_VERIFY.sql          (optional, read-only; use -IncludeVerify)

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
         (runner-managed via manifest path; not a manual SQL Editor step)

Phase 3c orbit-phase3/08_phase_3c_duval_wall.sql

Phase 3d orbit-phase3/09_transit_mode.sql

Phase 3e orbit-phase3/10_auth_tenant_jwt_hook.sql
```

Do **not** run `orbit-phase1/00_sweep_reset_staging.sql` (`-IncludeSweep`). It is destructive.

---

## Files that exist only outside `supabase/migrations`

All of `orbit-phase1/*`, `orbit-phase2/*`, and `orbit-phase3/01`–`07`. Those must be applied via the runner (or SQL Editor in the same order). Do not copy them into `supabase/migrations/` as part of this staging connect.

Phase 3b lives only at `supabase/migrations/phase_3b_lockdown.sql`. The runner applies that existing file; do not duplicate it into `orbit-phase3/`.

Duplicates (same content, two paths — use the `orbit-phase3/` copies when using the runner):

- `08_phase_3c_duval_wall.sql` ↔ `supabase/migrations/phase_3c_duval_wall.sql`
- `09_transit_mode.sql` ↔ `supabase/migrations/phase_3d_transit_mode.sql`
- `10_auth_tenant_jwt_hook.sql` ↔ `supabase/migrations/20260814000000_phase_3e_auth_tenant_jwt_hook.sql`

---

## Operator commands (do not run until this plan is approved)

From the Documents / `orbit_systems` repo root. Target **only** staging project `ydlwukjzqtssbzirnefs`. Use `orbit-tools/run-orbit.ps1`. Never point `.env`, `supabase link`, or `config.toml` at production.

```powershell
# 1. Confirm config points at staging (must be ydlwukjzqtssbzirnefs, never production)
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

# 5. Preview only (includes Phase 3b automatically between 07 and 08)
.\orbit-tools\run-orbit.ps1 -Phase all -IncludeVerify -DryRun

# 6. After approval: apply (no sweep). Phase 3b is included; do not execute it separately.
.\orbit-tools\run-orbit.ps1 -Phase all -IncludeVerify
```

Do **not** manually execute `supabase db execute -f supabase/migrations/phase_3b_lockdown.sql`. The runner already applies that file in the canonical position.

After the apply succeeds, validate SQL (below). Enable the Custom Access Token Hook in the Dashboard **only after** Phase 3e SQL has executed successfully **and** validation passes.

### Commands that must not be run

```text
supabase db reset
supabase db push
supabase functions deploy
.\orbit-tools\run-orbit.ps1 -IncludeSweep
supabase db execute -f supabase/migrations/phase_3b_lockdown.sql
```

`db push` is not the greenfield bootstrap path. `functions deploy` must not be used for `telemetry-ingress` during this database bootstrap.

---

## Dashboard steps (staging project only)

Confirm the URL is `https://ydlwukjzqtssbzirnefs.supabase.co`. Do not enable the hook on production from this plan.

1. After Phase 3e SQL has succeeded **and** validation passes: **Authentication → Hooks → Custom Access Token** → enable `public.custom_access_token_hook`. See `docs/AUTH_TENANT_HOOK_DEPLOY.md`.
2. Create at least one staff user and a `staff_profiles` row with `district_id` before expecting RLS reads.
3. Auth → URL config: add Lovable / local origins when wiring UI (not required to apply SQL).

---

## Edge Functions

`supabase/functions/telemetry-ingress/index.ts` is **not** part of the SQL runner.

Do **not** deploy it during this database bootstrap. Known defect: it inserts `position` while `bus_telemetry_logs` uses `location`. Fix before any later `supabase functions deploy --project-ref ydlwukjzqtssbzirnefs`.

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

Then run `supabase/AUTH_TENANT_HOOK_VALIDATE.sql` (read-only). Run `docs/AUTH_TENANT_HOOK_TEST_PLAN.md` only after the Dashboard hook is enabled.

---

## Rollback

Staging only:

1. Dashboard → disable Custom Access Token hook.
2. Do **not** drop Phase 1–3c objects as a rollback; restore from a staging backup / new empty staging project if the apply is wrong.
3. Never point rollback or restore at production.

---

## Safety

Staging deployment must:

- Target project `ydlwukjzqtssbzirnefs` only (`https://ydlwukjzqtssbzirnefs.supabase.co`).
- Use `orbit-tools/run-orbit.ps1` (not a manual Phase 3b SQL execute).
- **Not** use `-IncludeSweep`.
- **Not** use `supabase db reset`.
- **Not** use `supabase db push` for this greenfield bootstrap.
- **Not** deploy `telemetry-ingress` during this database bootstrap.
- Enable the Custom Access Token Hook manually only after Phase 3e SQL has successfully executed and validation passes.
- Never point staging configuration at the production project.

`orbit-tools/.env` stays gitignored. No service-role keys in git.
