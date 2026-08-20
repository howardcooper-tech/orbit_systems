# Orbit Staging Live-State Sync

> Environment: Supabase staging project `ydlwukjzqtssbzirnefs`
> Verified: 2026-08-20
> Status: **SIM-READY BACKEND BRIDGE — NOT PRODUCTION APPROVED**

This document is the GitHub-visible handoff for agents that cannot query Supabase directly. The live staging database remains the runtime source of truth. No simulator passwords or service credentials belong in this repository.

## Verified application state

- 44 Orbit application tables in `public` excluding PostGIS `spatial_ref_sys`.
- 5 Orbit application tables in `archive`.
- Orbit-owned public/archive tables use RLS + FORCE RLS.
- Simulator tenant: `81d25f6a-c459-5b6b-bc83-8e29e5847d50`.
- Six synthetic staging Auth users exist: 2 Pilots, 1 Command, 1 Central, 2 Parents.
- Four staff profiles exist: Pilot B01, Pilot B02, Command, Central.
- Two parent rows and four guardian links exist.
- Two trusted simulator Pilot tablets exist.
- B01 and B02 each have assigned Pilots and live location data.

## Simulator trip state

### B01 — normal/live rescue source

- Bus: B01
- Bus status: `Active`
- Grounded: false
- Trip status: `ready_for_boarding`
- Bus-trip handshake: `OPEN_FOR_BOARDING`
- Pilot assigned: yes
- Location available: yes

### B02 — pending/exception and rescue candidate

- Bus: B02
- Bus status: `Active`
- Grounded: false
- Trip status: `pending_bus_assignment`
- Bus-trip handshake: `PENDING_PILOT_ACCEPT`
- Pilot assigned: yes
- Location available: yes

The current `transfer_manifest_to_rescue` backend rejects rescue buses that own another `OPEN_FOR_BOARDING` or `LOCKED_DEPARTED` trip. A `PENDING_PILOT_ACCEPT` handshake does not currently make a bus ineligible, so B02 is a valid candidate for the B01 rescue simulation.

## Auth / tenant chain

`resolve_orbit_tenant_id(p_user_id uuid)` was repaired after the prior implementation attempted `MIN(uuid)`. The live implementation builds a distinct UUID tenant candidate set and returns the tenant only when exactly one tenant resolves.

`custom_access_token_hook(event jsonb)` is deployed and is restricted to `supabase_auth_admin`; `anon` and `authenticated` cannot execute the hook directly.

Database-side JWT impersonation verifies both Command and Central resolve the correct role and tenant and can read their permitted tenant-scoped rescue/fleet data.

**Manual gate remains:** confirm in the Supabase Auth dashboard that the Custom Access Token Hook is toggled **Enabled**. A public browser password-login/token exchange has not yet been proven from the connector runtime.

## Security hardening applied 2026-08-20

Migration source on this branch:

- `supabase/migrations/20260820_01_fix_orbit_tenant_resolver_uuid_aggregation.sql`
- `supabase/migrations/20260820_02_harden_client_surface_and_rescue_visibility.sql`
- `supabase/migrations/20260820_03_bridge_command_live_manifest.sql`

### Client privilege hardening

For browser roles (`anon`, `authenticated`):

- removed `TRUNCATE`, `REFERENCES`, `TRIGGER`, and `MAINTAIN` privileges from Orbit-owned public tables;
- `staff_profiles` no longer permits authenticated users to update `role`, `roles`, `district_id`, or other authorization/admin fields;
- authenticated self-service updates are limited to `preferred_language`, `profile_photo_url`, and `is_on_duty`;
- `staff_view_self` and `staff_update_self` are explicitly `TO authenticated` and use `auth.uid() = id`, with `WITH CHECK` on update.

Verified live:

- authenticated can update `preferred_language`;
- authenticated cannot update `role`, `roles`, or `district_id`;
- authenticated cannot truncate `staff_profiles` or `buses`.

### Internal privileged functions

Browser EXECUTE was revoked from infrastructure-only trigger/event-trigger helpers including:

- `gate_transit_mode_trip()`
- `gate_transit_trip_session()`
- `process_forensic_audit()`
- `rls_auto_enable()`
- `sync_transit_trip_from_trip()`
- `sync_trip_lock_from_transit()`
- `worm_log_trip_manifest()`

The mutable-search-path findings were also corrected for:

- `set_updated_at()`
- `deny_telemetry_mutation()`

### Command / Central rescue graph

Explicit tenant-scoped permissive SELECT policies now exist for Command/Central/Superintendent on:

- `bus_trip_handshakes`
- `rescue_handshakes`
- `halo_sessions`

Reference reads for `schools` and `contractors` were also added for authorized operational roles.

Central JWT verification currently sees:

- 2 buses
- 2 bus-trip handshakes
- 0 active rescue handshakes
- 0 HALO sessions
- 0 emergency flares
- 0 telemetry rows

The zero incident counts are expected until the rescue SIM is executed.

## Command compatibility bridge

`public.view_command_live_manifest` now exists as a PostgreSQL 15+ `security_invoker` view. It maps the current Orbit bus schema into the shape expected by the existing Lovable Command map/grid while preserving underlying RLS.

It currently returns B01 and B02 for the Command/Central simulator tenant and derives UI route state from the current bus state. It uses live bus/school geometry with a Jacksonville fallback only when no stored location is available.

## Live rescue RPC contract

```text
transfer_manifest_to_rescue(
  p_broken_trip_id uuid,
  p_rescue_bus_id uuid
) -> jsonb
```

The frontend must pass the broken **trip id**, not an original bus id. The RPC remains the sole owner of the coordinated rescue mutation: broken-bus grounding, bus-trip handshake cutover, student/manifest reassignment, emergency flare, HALO session, rescue handshake, and WORM audit record.

## Frontend staging bridge

Frontend work is isolated in `howardcooper-tech/orbit-bus-tracker` draft PR #1 on branch:

`sync/live-sim-auth-rescue-2026-08-20`

That branch:

- removes obsolete `user_roles` auth routing and public self-registration;
- routes web users from live `staff_profiles.role`;
- guards Command/Central portals by authenticated persona;
- replaces the old destructive trip-delete test with live rescue dispatch;
- calls `transfer_manifest_to_rescue(p_broken_trip_id, p_rescue_bus_id)`;
- binds active trip ownership through `bus_trip_handshakes`;
- adds Central recovery reconciliation across `buses`, `emergency_flares`, `rescue_handshakes`, `halo_sessions`, `bus_trip_handshakes`, and `bus_telemetry_logs`.

No simulator passwords are committed.

## Current Security Advisor standing

The 2026-08-20 advisor rerun no longer reports the prior application-owned anonymous trigger-helper exposures or mutable-search-path warnings.

Remaining findings fall into two groups:

### Extension-managed / platform-level

- `public.spatial_ref_sys` RLS disabled (PostGIS-owned).
- PostGIS installed in `public`.
- PostGIS `st_estimatedextent(...)` SECURITY DEFINER functions executable by browser roles.

Do not blindly modify these objects as though they were Orbit tables/functions; handle PostGIS relocation/hardening as a dedicated migration.

### Authenticated SECURITY DEFINER review

The advisor still flags authenticated execution for functions that are either intended client RPCs or helper functions requiring classification, including:

- `can_activate_transit_mode`
- `can_assist_transit_mode`
- `get_my_contractor`
- `get_my_district`
- `get_my_role`
- `link_sis_account`
- `parent_zone1_im_here`
- `pilot_assigned_manifest_scan`
- `transfer_manifest_to_rescue`
- `transit_hierarchy_for`
- `verify_student_pin`

Do not revoke these indiscriminately. Each must be classified as client-callable vs internal and tested before changing grants.

Supabase Auth also reports leaked-password protection disabled.

## Production release gate

**Production remains untouched and this build is not production approved.**

Before production candidate status:

1. confirm/enable the Custom Access Token Hook in the staging Auth dashboard;
2. perform real browser sign-in for Command and Central and verify top-level JWT `tenant_id`;
3. run B01 -> B02 rescue end to end;
4. verify Central recovery UI updates without refresh;
5. verify Parent/Pilot mobile flows;
6. classify remaining authenticated SECURITY DEFINER grants;
7. address or explicitly accept PostGIS/Auth advisor findings;
8. rerun advisors and full E2E regression.
