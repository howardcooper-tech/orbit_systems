# Orbit Bay Foundation

Orbit Bay is one synchronized maintenance suite with three client classes. The
Supabase database is the canonical durability layer; the Main Hub is the
authoritative Bay console and source-of-truth view presented to personnel.

## Client classes and authority

| Client | Typical hardware | Primary use | May schedule/down/return a bus? |
| --- | --- | --- | --- |
| Main Hub | Desktop, all-in-one, or locked laptop | Fleet-wide catalog, work control, inspection intake, administrative actions | Yes, through a live Hub session, explicit staff authorization, and fresh credentials |
| Workstation | Client box or rugged laptop on a cart | Ticket queue, repair notes, inspection workflow, tablet handoff | No |
| Rugged tablet | Replaceable Windows/Android/iPad-class field device | Roving inspection, camera capture, live repair updates | No |

Any eligible technician can receive Hub authorization. Manager/supervisor is a
separate override privilege, not the only way to perform a normal Hub action.

## Dynamic workstation and tablet continuity

A tablet is never permanently assigned to a workstation. Logging in while an
eligible tablet is docked creates one leased `bay_work_sessions` record binding
the technician, workstation, and tablet. Undocking or temporary loss of service
does not destroy that session. The client maintains a local encrypted outbox and
replays idempotent mutations after connectivity returns.

If the tablet fails, `bay_replace_tablet` ends the old pairing, releases the old
hardware assignment, creates a successor session, moves the active ticket claim
to the successor, and binds the replacement tablet. Logging out clears the
tablet assignment. Dock presence itself must be attested by the Flutter/device
integration; the database never pretends that a physical dock event occurred.

No raw Supabase token is copied between clients. Each device owns its own session.
The pairing record and realtime subscriptions provide continuity of work state.

## Ticket queue

`bay_claim_work_order` performs an atomic row lock and optional lock-version
check. A successful pull sets the technician, session, assignment, and
`In_Progress` state in one transaction, so another technician cannot pull the
same ticket. Tickets may also be assigned with `bay_assign_work_order`.

Work notes live in `bay_work_order_notes`. `client_mutation_id` and `lock_version`
support offline replay and conflict handling across the workstation and tablet.

## Inspections and inline photos

`bus_inspections` catalogs `Pre_Trip`, `Mid_Trip`, and `Post_Trip` records from
the Pilot App and Bay clients. Each item is a `bay_inspection_checkpoints` row
containing the technician's description and result.

Photos are optional for every checkpoint. The camera button belongs beside the
description control. Binary files use the private `bay-inspection-media` bucket;
`bay_inspection_media` stores immutable evidence metadata and links each image to
that exact checkpoint. The Hub renders attachments immediately beside the same
description rather than in a detached gallery.

Storage paths are fixed to:

```text
{tenant_uuid}/{checkpoint_uuid}/{media_uuid}.{jpg|png|webp|heic}
```

The bucket is private, limited to 20 MB per object, and protected by authenticated
tenant/checkpoint RLS policies.

## Hub-only administrative actions

The following actions are accepted only through a current `bay_hub_sessions`
record:

- `bay_schedule_maintenance`
- `bay_down_vehicle`
- `bay_return_vehicle_to_service`

Before calling one of these RPCs, the Hub reauthenticates the operator through
Supabase Auth. The database accepts a password, TOTP, or SSO/SAML AMR timestamp
no older than five minutes and records the Auth `session_id`. Raw passwords never
enter PostgreSQL.

Downing and returning a bus writes an immutable `bay_vehicle_service_events`
record containing the requesting technician, authorizing operator, Hub/session,
credential time, prior/resulting vehicle state, and override reason. Return to
service is blocked by unresolved critical-grounded work or an unsafe latest
inspection unless an authorized supervisor supplies an override reason.

## Access model

- In-house districts: active Crew, Command, Central, or Superintendent staff can
  manage Bay when the tenant has the `BAY` capability.
- Outsourced maintenance: active contractor Crew/Control assigned to the tenant's
  maintenance contractor can manage Bay.
- District Central oversight remains read-only in the outsourced model.
- Pilot/Halo personnel can submit and maintain their own assigned-bus Pilot App
  inspections, checkpoints, and optional photo metadata.
- All Bay tables use RLS; the eleven new `bay_*` tables also force RLS.

## Realtime and offline state

Realtime publication includes work orders, inspections, Hub/work sessions,
schedules, vehicle service events, notes, checkpoints, and media metadata.
Clients should model mutations as `local_pending`, `syncing`, `synced`, or
`conflict`. Realtime is an acceleration path, not the durability mechanism;
reconnect always performs a server reconciliation by ID, `client_mutation_id`,
and `lock_version`.

## Source and deployment order

1. `orbit-phase3/14_bay_suite_foundation.sql`
2. `orbit-phase3/15_bay_suite_session_hardening.sql`
3. `orbit-phase3/16_bay_suite_rls_helper_grants.sql`
4. `orbit-phase3/17_bay_suite_query_plan_hardening.sql`
5. `orbit-phase3/18_bay_dev_seed_optional.sql` only for dev/staging
6. `orbit-phase3/19_ecosystem_security_hardening.sql`
7. `orbit-phase3/20_telemetry_ingress_hardening.sql`

Migration 14 deliberately fails closed unless the tenant JWT resolver, `BAY`
capability function, and WORM ledger are already present.

## Staging verification

Verified on Orbit Systems Staging on 2026-09-09. All test transactions rolled
back their generated data.

- Hub schedule → pair → claim → replace tablet → release → down → return → logout
- stale AMR credential rejection
- outsourced district oversight read/write boundary
- Pilot inspection → checkpoint → optional inline media metadata → submit
- private Storage bucket and object-policy structure
- post-migration security and performance advisor review
- explicit JWT tenant gates on every public tenant-table policy
- cross-tenant bus-inspection reference rejection
- trigger-only function RPC revocation
- complete foreign-key leading-index coverage
- Edge Function browser-origin restriction to the private Lovable staging portal
- tenant-consistent telemetry rows and a per-bus ingress rate window

Authenticated `SECURITY DEFINER` RPC endpoints remain intentionally executable;
they use explicit grants and perform tenant, role, session, and authorization
checks. PostGIS remains extension-owned in `public` on this existing project;
install it in `extensions` when provisioning the clean production project.
Fresh indexes may report as unused until normal staging traffic exercises them.
