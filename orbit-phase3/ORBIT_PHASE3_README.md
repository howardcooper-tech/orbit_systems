# Orbit Atom — Phase 3 (The Brain)

Run **after Phase 2** (or after Phase 1 if you skip seed and load SIS later).

Adds: security definer helpers, **Duval Wall RLS**, forensic audit triggers, `updated_at` triggers, telemetry INSERT-only guard.

`02_enable_rls.sql` skips PostGIS `spatial_ref_sys` (extension-owned, not alterable by `postgres`).

## Run order

| # | File |
|---|------|
| 1 | `01_core_functions.sql` |
| 2 | `02_enable_rls.sql` |
| 3 | `03_rls_duval_wall.sql` |
| 4 | `04_audit_triggers.sql` |
| 5 | `05_telemetry_immutable.sql` |
| 6 | `06_updated_at_triggers.sql` |
| 7 | `07_business_gates.sql` |

## After Phase 3

```sql
SELECT count(*) FROM pg_policies WHERE schemaname = 'public';
SELECT tgname FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND tgname LIKE 'trig_audit_%';
```

Test as `authenticated` JWT in Supabase — **not** service role (service role bypasses RLS).

## Deferred to Phase 3b (optional later)

- `fn_archive_stale_data` (Chronos) — archive copy only, no hot DELETE
- Mesh / rescue / halo auto-triggers
- `supabase_realtime` publication adds
- Auto-grounding bus on inspection
