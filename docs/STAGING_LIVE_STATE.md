# Orbit Staging Live-State Sync

> Environment: Supabase staging project `ydlwukjzqtssbzirnefs`
> Verified: 2026-08-19 17:54 UTC
> Status: **STAGING VERIFIED — NOT PRODUCTION APPROVED**

This document is a relational-awareness handoff for agents that can read GitHub but cannot query Supabase directly. The live database remains the runtime source of truth; this snapshot records the state verified on 2026-08-19.

## Verified live state

- 44 application tables in `public` (excluding PostGIS `spatial_ref_sys`).
- 5 archive tables in `archive`.
- All 49 Orbit application/archive tables have RLS enabled and FORCE RLS enabled.
- `public.students` contains `pin_hash` and `tenant_id`.
- `public.student_guardians` links `student_id -> students.id` and `parent_id -> parents.id`.
- `public.trip_manifest.assigned_bus_id -> buses.id`.
- `public.student_scan_events` contains `parent_id`, `headshot_url`, `waypoint_id`, and tenant-aware foreign keys.
- Transit-mode tables are live: `transit_trips`, `transit_satellite_roster`, `satellite_units`.
- Rescue/incident tables are live: `emergency_flares`, `halo_sessions`, `halo_manifest_snapshots`, `rescue_handshakes`, `incident_dispatch_logs`.
- WORM/audit layer is live: `audit_worm_ledger` plus archive audit tables.

## Verified live functions / integrations

### `link_sis_account(p_sis_student_id text, p_date_of_birth date)`

The live function:
1. resolves the active SIS enrollment and tenant,
2. creates the parent row when needed,
3. inserts the guardian authorization into `public.student_guardians`, and
4. prevents duplicate student/parent links.

This closes the prior relational gap where SIS linking could create a parent without a `student_guardians` authorization row.

### `telemetry-ingress` Edge Function

Live Supabase version: **v2**, JWT verification enabled.

The canonical live implementation writes:

- `bus_id`
- `location` as `SRID=4326;POINT(longitude latitude)`
- `device_timestamp`
- `recorded_at`

The obsolete `position` payload is no longer used. The GitHub copy on this sync branch has been updated to match the live v2 implementation.

### `parent_zone1_im_here` Edge Function

Live Supabase version: **v1**, JWT verification enabled.

The function validates the authenticated guardian, calls the `parent_zone1_im_here` RPC, writes/uses `student_scan_events`, and broadcasts a Zone 1 custody event to the pilot tablet topic when authorized.

## Production release gate — FAILED as of this snapshot

Supabase Security Advisor still reports issues that must be resolved before production approval. Important application-level items include:

- `public.set_updated_at` has mutable `search_path`.
- `public.deny_telemetry_mutation` has mutable `search_path`.
- Several `SECURITY DEFINER` functions are executable by `anon`, including internal transit/audit helpers such as `gate_transit_mode_trip`, `gate_transit_trip_session`, `process_forensic_audit`, `rls_auto_enable`, `sync_transit_trip_from_trip`, and `sync_trip_lock_from_transit`.
- Multiple `SECURITY DEFINER` RPCs are executable by `authenticated`; each grant must be reviewed intentionally, including `link_sis_account`, `parent_zone1_im_here`, transit helpers, rescue transfer, PIN verification, and role/district helper functions.
- Supabase also flags PostGIS objects in `public` (`spatial_ref_sys` RLS and extension placement). Treat these separately from Orbit-owned application tables when remediating.

**Do not label this build production-ready until the security advisor is re-run and the application-level findings are either remediated or explicitly accepted with documented rationale.**

## Source-of-truth workflow for Gemini / GitHub-only agents

1. Treat migrations in this repository as the intended schema history.
2. Treat this live-state sync as the latest verified runtime state.
3. When this file and migrations disagree, flag schema drift rather than guessing.
4. A Supabase-connected operator should refresh this sync after material DDL, RLS, RPC, trigger, or Edge Function changes.
5. Production approval requires a clean/accepted security-advisor review plus passing end-to-end beta flows.
