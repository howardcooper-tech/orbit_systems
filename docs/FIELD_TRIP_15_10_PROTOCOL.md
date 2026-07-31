# Field trip — missing child protocol (15/10)

**Scope:** `trips.trip_type = 'Field_Trip'` only.  
**Policy order:** **15 minutes** primary sweep → **10 minutes** Satellite physical verification (backup).

---

## Trigger

Student is **not accounted for** on the field trip (not on bus / not located at venue).

- Set student `current_status` / `missing_status` per operational rules.
- Open or link `emergency_flares` with `search_timer_status = '15m_Active'` and `search_timer_started_at`.
- Begin **immutable event log** (append-only; not a parent alert).

---

## Phase A — 15-minute primary sweep (`15m_Active`)

**Goal:** Locate the child on-site or on any bus assigned to the `trip_id`.

| Actor | Action |
|-------|--------|
| **Node / Satellite** | Venue / chaperone-group search |
| **Pilot** | Search vehicle(s) on this `trip_id` (`bus_trip_handshakes`); child may have re-boarded unnoticed |
| **Command** | Manifest alert (“hit” on missing student) |
| **Central** | School-admin coordination |

A **report of “found”** by Node, Pilot, or another Satellite during this phase does **not** close the incident. It starts the need for **assigned Satellite verification** in Phase B.

### Point (parent) — Phase A

**No parent notification** during the 15-minute sweep.

---

## Phase B — T+15: internal escalation (still no Point)

When **15 minutes elapse** without **Satellite-verified** resolution:

| Recipient | Live alert? |
|-----------|-------------|
| **Central** | Yes |
| **Command / Pilot** | Yes (manifest + vehicle search context) |
| **EMS / local authorities** | Per Command (`incident_dispatch_logs`) |
| **Point (parent)** | **No** |

Transition: `search_timer_status` → `'10m_Backup_Active'`.

---

## Phase C — 10-minute Satellite verification (`10m_Backup_Active`)

**Purpose:** Confirm a **located** child is the **correct** missing student and close the incident with accountability.

This is **not** a second open-ended search and **not** a parent-notification phase.

| Rule | Detail |
|------|--------|
| Who may have located the child | Node, Pilot, alternate Satellite, or on-site staff during Phase A |
| Who must verify | **Assigned Satellite** on the trip **or** **Lead Satellite** (`lead_satellite_id` / `Lead_Satellite` role) |
| Physical requirement | Must go to the **physical location** of the reported “found child” |
| Confirmation | Verify identity (badge scan) **and** **teacher code** acknowledgment |
| Accountability | Verifying Satellite **takes responsibility** for the confirmation (logged immutably) |

### Point (parent) — Phase C

**No parent notification during the entire 10-minute backup window.**

Parents are not alerted while Satellite is en route to verify a possible recovery.

| Outcome | `search_timer_status` | Point live alert? |
|---------|----------------------|-------------------|
| Satellite verifies correct child | `Resolved_Verified` | **No** (after-action only at reboarding) |
| 10 minutes elapse, child still not found / not verified | `Escalated_Failed` | **Yes — first live parent notification** |

---

## Point notification summary

| Event | Point live alert? |
|-------|-------------------|
| During 15 min sweep | No |
| At start of 10 min backup (T+15) | **No** |
| During 10 min backup | **No** |
| Child verified found by Satellite | No |
| Child **not found** after full 15 + 10 protocol | **Yes** |
| End of trip reboarding | **After-action report always** (see below) |

---

## End of trip — after-action report (Point)

**Regardless of outcome** (verified found, or escalated not found):

At **reboarding / end-of-trip bus consolidation**, deliver an **after-action report** to the assigned parent (**Point**):

- Built from the **immutable event log** (full timeline)
- Post-trip transparency — not a mid-search panic push
- **Required even if the child was found** and no live parent alert was ever sent

---

## Immutable event log

Written on trigger and on every state transition (search reports, timer changes, verification, escalation).  
Supports compliance, Command review, and after-action reports.  
Distinct from `outbound_alerts` parent pushes.

---

## Schema anchors (Phase 1)

| Concern | Table / column |
|---------|----------------|
| Trip / manifest | `trips`, `trip_manifest`, `bus_trip_handshakes` |
| Lead Satellite | `trips.lead_satellite_id`, `staff_profiles.role` (`Lead_Satellite`, `Satellite`) |
| Chaperones | `trip_chaperone_groups`, `trip_chaperone_handshakes` |
| Timer | `emergency_flares.search_timer_status`, `search_timer_started_at` |
| Verification | `halo_manifest_snapshots.verification_type`, `search_verified_by_satellite_id` on flares |
| Student state | `students.current_status`, `students.missing_status` |
| Parent link | `student_guardians` → `parents` |
| Forensic | `audit_logs` |
| Staff / parent alerts | `outbound_alerts`, `incident_dispatch_logs` |

---

## Phase 3b automation checklist

- [ ] `15m_Active`: search fan-out; **block** Point `outbound_alerts`
- [ ] T+15: Central / Command / Pilot / EMS; **still block** Point
- [ ] `10m_Backup_Active`: assign verification task to trip Satellite / Lead Satellite; **block** Point
- [ ] `Resolved_Verified`: log verifier + teacher code; **no** Point live alert
- [ ] `Escalated_Failed`: **first** Point live alert + full escalation
- [ ] Reboarding complete: after-action report to Point **always**
- [ ] RLS: parents read only their reports / authorized scope

---

## App role map

| App | Role |
|-----|------|
| **Point** | `parents` — live alert only on protocol failure; after-action always |
| **Node** | Chaperone search; may report “found” |
| **Satellite / Lead Satellite** | Search + **mandatory physical verification** in backup window |
| **Pilot** | Vehicle search on trip buses |
| **Command / Central** | Ops escalation at T+15; not parent-facing |
