# Orbit Atom — Phase 1 (Structure Only)

Phase 1 creates tables, foreign keys, and indexes. **No triggers, no functions, no RLS policies.**

Run on a **new Supabase branch** or **empty staging project** first. Do not run on production until Phase 1 succeeds and you have reviewed the schema dump.

## Prerequisites

- Supabase project with **Auth** enabled (`auth.users` must exist — it does by default).
- SQL Editor or `psql` connected as `postgres`.
- If you already ran the old monolith on this database, **sweep first** (see step 0 below).

## Run order (strict)

| # | File | Creates |
|---|------|---------|
| 0 | `00_sweep_reset_staging.sql` | **Wipes `public` + `archive` (staging only)** |
| 1 | `01_extensions.sql` | PostGIS, uuid-ossp |
| 2 | `02_infrastructure.sql` | districts, contractors, schools, staff_profiles, parents, guardian_profiles |
| 3 | `03_students_sis.sql` | student_sis_enrollment (macro), students (micro/BLE), guardians, device auth |
| 4 | `04_fleet.sql` | buses, bus_telemetry_logs |
| 5 | `05_trips.sql` | trips, trip_manifest (RESTRICT), bus_trip_handshakes, audit_logs |
| 6 | `06_bay_comms.sql` | bus_inspections, maintenance_work_orders, comms |
| 7 | `07_mesh_iot.sql` | route_waypoints, trip_active_mesh, student_scan_events |
| 8 | `08_emergency.sql` | emergency_flares, incident_dispatch_logs |
| 9 | `09_field_routes.sql` | routes, route_stops, field_trip_venues, chaperone groups, checkouts |
| 10 | `10_halo_alerts.sql` | halo, rescue, outbound_alerts, drone_assets, trusted_hardware |
| 11 | `11_archive_schema.sql` | `archive` schema + cold-storage table shells |
| 12 | `12_indexes.sql` | Performance indexes |

Run **every file in order**, starting with **`00_sweep_reset_staging.sql`** if you need a clean slate. Each file is wrapped in `BEGIN` / `COMMIT`.

### Step 0 — Sweep (empty the DB)

**File:** `00_sweep_reset_staging.sql`

- Destroys every table, view, function, and type in `public` and `archive`.
- **Does not** delete `auth.users` (logins stay; you will re-link staff/parent rows in Phase 2).
- Use only on **staging** or a throwaway project — never production without a backup.

After sweep, confirm empty:

```sql
SELECT count(*) AS public_tables
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
```

## How to run in Supabase

1. Dashboard → **SQL** → New query.
2. Paste contents of `01_extensions.sql` → **Run**.
3. Repeat for `02` through `12`.
4. Confirm: **Database** → **Schema Visualizer** — tables appear, no errors.

Or copy the folder to `supabase/migrations/` with timestamp prefixes and use the CLI (optional).

## What Phase 1 fixes vs the old monolith

- Single **Nucleus** `trips` model (no duplicate JSON `master_manifest` trips table).
- `sis_student_id` + **`student_sis_enrollment`** (SIS macro separated from BLE `students` row).
- `trip_manifest.trip_id` → **`ON DELETE RESTRICT`** (audit protection from day one).
- `bus_inspections.inspection_status` (not renamed later from `status`).
- `comms_messages.sender_id` + `recipient_id` from day one.
- `bus_telemetry_logs` columns: `location`, `recorded_at`, `device_timestamp`, `synced_at`.
- No `public.profiles` (lowercase Pin RBAC) — staff use **`staff_profiles`** only in Phase 1.
- No `fleet_vehicles` parallel stack — use **`buses`** only.

## After Phase 1 succeeds

| Phase | What |
|-------|------|
| **Phase 2** | SIS backfill / import into `student_sis_enrollment`, link `students` |
| **Phase 3** | Functions, RLS (Duval Wall), audit triggers, telemetry INSERT-only |

Use `ORBIT_ATOM_SPEC_REMEDIATION.sql` as a **checklist** for Phase 3 — not as a single paste.

## Verify schema (optional)

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
```

```sql
-- Manifest must be RESTRICT (audit protection)
SELECT confdeltype
FROM pg_constraint
WHERE conname = 'trip_manifest_trip_id_fkey';
-- expect: 'r' (RESTRICT)
```

## If this database already has the old monolith

Run **`00_sweep_reset_staging.sql`**, then `01` → `12`.

Alternatives:

1. **Supabase branch** (Pro): new branch is already empty — skip sweep, run `01` → `12`.
2. **New staging project**: skip sweep, run `01` → `12`.

## Intentionally deferred to Phase 3

- `get_my_role()`, `process_forensic_audit()`
- All RLS policies
- Auto-grounding, mesh, halo, lockbox triggers
- `pg_cron` / Chronos archive jobs
- Realtime publication changes
