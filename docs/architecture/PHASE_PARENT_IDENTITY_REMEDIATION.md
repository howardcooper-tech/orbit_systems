# Parent identity remediation — 2026-10-23

Decision: **NO-GO — REMEDIATION REQUIRED.**

The parent-identity blocker is not cleared. Hosted cross-parent calls were not run.

## What was verified by reading staging

Project `ydlwukjzqtssbzirnefs`, us-east-1, Postgres 17.6.1.155, ACTIVE_HEALTHY. Production was listed and not queried.

| Fact | Evidence |
| --- | --- |
| Migration `20261022135614` `bind_parent_student_authorization_to_auth_uid_20261022` | Present in `supabase_migrations.schema_migrations`. The SQL file is not in git. |
| `is_parent_of_student` | Security definer. Requires `auth.uid()` and rejects a different `p_parent_id`. Looks up `student_guardians` by `auth.uid()`. Does not compare `tenant_id` to the JWT. |
| `satellite_record_paper_chaperone_application` | Staff caller must be the assigned teacher or a lead. The parent id is the selected guardian, after that staff check. The invitation lookup does not filter `tenant_id`. |
| `link_sis_account` on staging | Uses `auth.uid()` and date of birth. Does not insert `student_guardians`. Does not call `jwt_tenant_id()`. |
| Uncommitted local `orbit-phase2/02_sis_import_helpers.sql` | Would insert a guardian row from SIS id and date of birth. Left untouched. Not applied. |
| `parents`, `student_guardians`, `students` | RLS forced. Parent reads require `id` or `parent_id` = `auth.uid()` and the JWT tenant. |
| `parent.a` and `parent.b` @ `orbit-sim.example.com` | 2 guardian links each, 0 shared students, 1 shared district. Not a two-district pair. |
| `orbit_runtime_settings` | `environment_name` staging. `allow_test_family_binding` true. `allow_beta_manual_onboarding` true. Flags were not changed. They do not replace authorization. |

No passwords or tokens were read.

## Blocker matrix

| Blocker | Root cause | Object | Change | Acceptance | Evidence | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Parent id substitution in Point | Gateway filtered on the supplied id | `supabase_*_gateway.dart` | Reject when the id is not `auth.currentUser` | Unit test | Local | FAIL for hosted API |
| Cross-parent API isolation | Needs both JWTs | `student_guardians`, `students` | None applied | Both directions | Report JSON | BLOCKED |
| Cross-district isolation | These two parents share a district | Fixture sheet unsigned | None | Two districts | C.10 | BLOCKED |
| Invite send | No transport window, cancel, or resend contract | Profile dialog | Dialog explains that nothing was sent and does not submit | Widget test | Local | NOT a sent invitation |
| Settings project ref | Release copy included the ref | `point_settings_page.dart` | Debug-only | Widget test with the flag off | Local | PASS for the widget |
| `is_parent_of_student` tenant | Definer skips the tenant column | New migration file | Not applied | Hosted parent calls | Read of live body | BLOCKED |
| Paper chaperone tenant | Invitation lookup has no tenant filter | Same unapplied file | Not applied | Staff fixture | Read of live body | BLOCKED |
| SIS binding | Owner decision open. Staging function does not insert | `link_sis_account` | Not changed | SIS owner | Staging body does not insert | BLOCKED |
| `transit_hierarchy_for` | Authenticated callers can pass another staff id | Function grant | Not changed. Authorization callers pass `auth.uid()` | Caller review | Source | BLOCKED |
| `spatial_ref_sys` | Prior write grants | D1 | Not changed | `supabase_admin` | C.8 | BLOCKED |
| Telemetry v5 | Unverified hash | Edge function | Not called | Owner matrix | C.10 | BLOCKED |
| Rescue | Unaccepted predicate | D5 | Not restored | Safety owner | C.8 | BLOCKED |

## Files in this change

- `orbit-point` settings, invite dialog, and the two Supabase gateways.
- Tests for the release string, the acting-parent check, and the invite dialog.
- `supabase/migrations/20261023143000_parent_identity_tenant_match.sql` — not applied.
- `docs/evidence/parent-isolation-report.json`.

## Invitation contract still required

Do not add a send path until a signed contract defines the transportation window, expiration, revocation, resend, recipient verification, the rule that acceptance does not grant a guardian link, audit events, and tests for both synthetic parents.

## Staging apply, only after review

Apply `20261023143000_parent_identity_tenant_match.sql` on `ydlwukjzqtssbzirnefs` only. Do not apply the uncommitted SIS helper. Rollback is the function bodies read on 2026-10-23, which are stored in the Phase 0 notes of this session and in the migration comment's predecessor `20261022135614`.

## Next action

Issue short-lived tokens for `parent.a` and `parent.b` without putting them in git, then run the blocked isolation cases. A green widget test does not clear this blocker.
