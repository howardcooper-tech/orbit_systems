# Orbit Atom — Architectural SPEC Audit

**Project:** Orbit Systems (StateRAMP-ready student transportation)  
**Artifact audited:** `Orbit Atom Script.txt` (~3,400 lines, stacked migrations)  
**SPEC version:** ORBIT ATOM ARCHITECTURAL CONSTRAINTS (3 pillars)  
**Audit date:** 2026-05-20

---

## Executive summary

The monolith is **not SPEC-compliant** as a single deployable script. It encodes **at least three generations** of schema (Nucleus V25.1 → operational partitions → Jacksonville Alpha / V35 routes) with overlapping tables, duplicate blocks, and late patches that only partially correct earlier violations.

| SPEC rule | Result |
|-----------|--------|
| `sis_student_id` as SIS PK/join key | **FAIL** |
| SIS enrollment vs BLE status strictly separated | **FAIL** |
| No cascade delete `trips` → `trip_manifest` | **PARTIAL** (RESTRICT added late) |
| All RLS uses `public.get_my_role()` | **FAIL** |
| Every BASE TABLE has `trig_audit_*` | **FAIL** |
| `bus_telemetry_logs` INSERT-only | **FAIL** |

**Recommendation:** Stop running the full monolith on non-empty databases. Adopt ordered Supabase migrations: `001_nucleus` → `002_partitions` → `003_spec_remediation` (see `ORBIT_ATOM_SPEC_REMEDIATION.sql`). Pick **one** trip model (Nucleus relational recommended for StateRAMP audit trails).

---

## 1. Data integrity

### 1.1 `sis_student_id` as PK/SIS join key — FAIL

**Nucleus `students` definition:**

- Primary key: `id UUID` (internal surrogate)
- No `sis_student_id`, no `date_of_birth`

**Later code assumes SIS columns exist:**

- `link_sis_account(p_student_id text, p_student_dob date)` queries `sis_student_id` and `date_of_birth`
- `profiles.student_id` is `text`, not FK-linked to a canonical SIS key

**Impact:** SIS import, parent/student linking (Lovable/Trust), and cross-district identity are undefined. StateRAMP assessors expect a stable external student identifier.

**Remediation:** Add `sis_student_id TEXT NOT NULL` with `UNIQUE (school_id, sis_student_id)` or district-scoped unique; keep `id` as internal UUID. See remediation migration §1.

---

### 1.2 Enrollment (macro/SIS) vs BLE (micro) — FAIL

**SPEC:** Macro SIS logic and micro BLE logic must be **strictly separated**.

**Current state (same table `students`):**

| Column | Layer | Notes |
|--------|--------|------|
| `enrollment_status` | SIS (added later) | `active`, `graduated`, `withdrawn` |
| `current_status` | BLE/ops | `off_bus`, `boarded`, `missing`, `medical_hold` |
| `missing_status` | Ops/flare | BLE-adjacent |
| `status_note` | Mixed | Set by checkout/flare functions on `students` |

**Coupling examples:**

- `handle_graduation` trigger on `students.enrollment_status` updates `profiles.preferred_app`
- Boarding functions update `halo_manifest_snapshots.status` and `students.current_status` in one flow
- Checkout sets `current_status` + `status_note` on `students`

**Remediation:** `student_sis_enrollment` (macro) + `student_presence_state` (micro), or strict columns + trigger forbidding cross-layer updates. See remediation migration §2.

---

### 1.3 No cascade delete `trips` → manifests — PARTIAL

**Original violation:**

```sql
trip_id UUID REFERENCES public.trips(id) ON DELETE CASCADE  -- trip_manifest
```

**Late fix (Audit Preservation Protocol) — correct for FK path:**

```sql
FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE RESTRICT;
```

**Remaining risks:**

| Risk | Detail |
|------|--------|
| Student CASCADE | `trip_manifest.student_id` still `ON DELETE CASCADE` — deleting student erases manifest history |
| Other trip children | `route_waypoints`, `trip_active_mesh`, `bus_trip_handshakes`, `comms_channels`, `field_trip_checkouts`, `trip_bus_assignments` still CASCADE |
| Lockbox purge | `fn_execute_trip_lockbox_purge` DELETEs halo snapshots, comms, checkouts — not FK cascade but destroys operational audit surface |
| Status mismatch | Lockbox checks `'Completed'`, `'Canceled'`; Nucleus uses `'completed'`, `'canceled'` — purge may never fire |

**Triggers:** No trigger found that DELETEs `trip_manifest` when a trip is deleted. RESTRICT on `trip_id` satisfies the SPEC for FK cascade.

---

## 2. Security boundaries

### 2.1 Duval Wall — all RLS must use `get_my_role()` — FAIL

**Compliant (examples):** `crew_manage_inspections`, `command_view_district_*`, `flare_visibility` (partial), `ops_manage_active_mesh`, `pilot_manage_scans`, later `satellite_view_huddle`.

**Non-compliant (direct `staff_profiles` / `profiles` subqueries):**

| Policy | Issue |
|--------|--------|
| `pilot_view_fleet`, `pilot_insert_telemetry`, `pilot_view_trips` | Subquery on `staff_profiles` |
| `"Orbit Map Visibility Policy"` | `(SELECT role FROM staff_profiles …)` |
| `contractor_fleet_isolation`, `contractor_inspection_isolation` | Same pattern |
| `custody_waiver_logs.select_own_waivers` | Subquery, not `get_my_role()` |
| All `public.profiles` policies | Separate RBAC (`central`/`point` lowercase) |

**Parent policies** (`parent_view_self`, etc.) use `auth.uid()` only — acceptable for parent tables if SPEC is interpreted as staff RLS only; document explicitly.

**Role fragmentation:** Nucleus roles (`Satellite`, `Teacher`, `Central`) vs Jacksonville (`Staff_Teacher`, `Lead_Satellite`, `Superintendent`) vs `profiles` (`central`, `point`). Policies referencing `'Satellite'` silently deny `'Staff_Teacher'` users.

---

### 2.2 Every BASE TABLE has `trig_audit_*` — FAIL

**Nucleus loop:** Attaches audit to public BASE TABLES except `audit_logs`, `bus_telemetry_logs`, `spatial_ref_sys`.

**Explicit exclusions in script:**

- `comms_messages` (volume)
- `student_scan_events` (volume/immutable intent)

**Tables added later — no audit attachment in monolith:**

`outbound_alerts`, `drone_assets`, `halo_sessions`, `halo_manifest_snapshots`, `rescue_handshakes`, `trip_bus_assignments`, `tactical_requests`, `field_trip_checkouts`, `field_trip_venues`, `trip_chaperone_groups`, `trip_chaperone_handshakes`, `trusted_hardware`, `guardian_profiles`, `routes`, `route_stops`, `profiles`, `secondary_authorized_profiles`, `student_secondary_authorizations`, `custody_waiver_logs`, `contractor_profiles`, `fleet_vehicles`, `vehicle_pre_trip_logs`, and others.

**Bug:** `process_forensic_audit()` always `RETURN NEW`; on `DELETE` should `RETURN OLD`.

**Denylist for SPEC (recommended):** Only `audit_logs`, `bus_telemetry_logs`, `spatial_ref_sys`, and optionally high-volume append-only tables if documented in compliance packet — not silent omission.

---

## 3. Immutable principles

### 3.1 `bus_telemetry_logs` INSERT-only — FAIL

| Violation | Location |
|-----------|----------|
| `DELETE FROM public.bus_telemetry_logs` | `fn_archive_stale_data()` (Chronos) |
| No DB-level deny trigger | Only RLS `FOR INSERT` for pilots |
| Wrong column in triggers | `NEW.location_gps`, `ORDER BY created_at` — table has `location`, `recorded_at` |

Service role and `SECURITY DEFINER` functions bypass RLS.

**Remediation:** `BEFORE UPDATE OR DELETE` trigger raising exception; archive via `INSERT INTO archive… SELECT` + detach/partition strategy, not hot-table DELETE. See remediation migration §5.

---

## 4. Structural collisions (rollout blockers)

### 4.1 Dual trip architectures

| Nucleus V25.1 | Later `CREATE TABLE IF NOT EXISTS` |
|---------------|-------------------------------------|
| `district_id`, `trip_code`, `destination`, `lead_satellite_id` | `proposed_by`, `trip_name`, `master_manifest` JSONB |
| `trip_manifest` rows | `trip_bus_assignments` + JSON |
| `bus_trip_handshakes` | Overlapping handshake semantics |

`IF NOT EXISTS` does not add missing columns — functions targeting `trip_name` fail on Nucleus-only DBs.

### 4.2 Parallel domains (pick one)

- Fleet: `buses` vs `fleet_vehicles` + `contractor_profiles`
- Guardians: `parents` + `student_guardians` vs `guardian_profiles`
- RBAC: `staff_profiles` vs `profiles` (Pin/Trust app)
- Routes: `route_waypoints` (per trip) vs `routes` / `route_stops`

### 4.3 Exact duplicate blocks in monolith

- Bay table alignment — **2×**
- Chassis / column injector — **2×**
- Mesh intelligence + trigger — **2×**
- `profiles` / graduation / `handle_new_user` — **4×+**
- Satellite huddle policies — **3×** (conflicting role lists)
- Enterprise indexing — **2×**

### 4.4 Runtime-breaking mismatches (sample)

| Reference | Problem |
|-----------|---------|
| `fn_auto_ground_bus` | `is_grounded`, `Maintenance_Required` not in Nucleus `buses` |
| `emergency_flares` inserts | `metadata`, invalid `flare_type` / `severity` vs CHECK |
| `bus_trip_handshakes.status = 'Active'` | Not in Nucleus enum |
| `fn_send_command_broadcast` | 5-arg vs 4-arg overloads; invalid `'Satellite'` scope arg |
| `trip_chaperone_groups` INSERT | Uses `chaperone_id` — table has `node_id`, `satellite_id` |
| `ALTER VIEW view_lead_satellite_mirror` | View may not exist yet |
| `msg_visibility` | References `recipient_id` before column patch order |

---

## 5. SPEC scorecard

```
[ ] sis_student_id PK/SIS join          → FAIL
[ ] SIS vs BLE status separation        → FAIL
[~] No trips→manifest CASCADE           → PARTIAL (RESTRICT ok; other risks remain)
[ ] All RLS via get_my_role()           → FAIL
[ ] trig_audit_ on every BASE TABLE     → FAIL
[ ] bus_telemetry_logs INSERT-only        → FAIL
```

---

## 6. Recommended execution order

1. **Freeze** canonical model: Nucleus relational trips + `staff_profiles` RBAC (deprecate duplicate `profiles` for staff).
2. **Run** `ORBIT_ATOM_SPEC_REMEDIATION.sql` on a staging Supabase branch.
3. **Split** monolith into versioned migrations; delete duplicate blocks from source.
4. **Align** Lovable/Flutterflow to `sis_student_id`, `trip_manifest`, `get_my_role()` roles only.
5. **Document** audit denylist + telemetry retention in StateRAMP SSP.

---

## 7. Files produced by this audit

| File | Purpose |
|------|---------|
| `ORBIT_ATOM_AUDIT.md` | This report |
| `ORBIT_ATOM_SPEC_REMEDIATION.sql` | Idempotent SPEC fix migration (staging first) |

---

## 8. Source of truth recommendation

For government audit and manifest integrity, standardize on:

- **Trips:** Nucleus (`trip_code`, `trip_manifest`, `bus_trip_handshakes`)
- **Students:** `sis_student_id` + `student_sis_enrollment` + `students.current_status` (micro only)
- **Security:** `staff_profiles` + `get_my_role()` only (migrate Pin app to `parents` / `student_guardians`, not lowercase `profiles`)

Retire or move to `legacy` schema: `fleet_vehicles`, duplicate `CREATE TABLE IF NOT EXISTS trips`, and repeated patch blocks.
