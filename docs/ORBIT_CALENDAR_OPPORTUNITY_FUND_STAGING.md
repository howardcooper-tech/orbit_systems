# Orbit Calendar & Opportunity Fund — staged implementation (15 Oct 2026)

## Actual deployment status

- **Supabase staging:** `ydlwukjzqtssbzirnefs` (ACTIVE_HEALTHY). Four database migrations applied and verified. No production changes.
- **Edge Function:** `orbit-calendar-ics` deployed in staging, JWT verification **on**. Creates a **one-time event download**; not provider-based continuous sync.
- **Flutter:** reusable source adapter in `packages/orbit-calendar-flutter/lib/orbit_calendar_repository.dart`; **not yet installed or wired into FlutterFlow screens**. FlutterFlow-generated Point, Pin, and Satellite projects are not held in this repository.
- **Financial transactions:** OFF. A CHECK constraint prevents setting `checkout_enabled=true` on `orbit_trip_funding_rules`. Donation intents are **not paid donations**. No payment provider secret, webhook, financial settlement, refund, or tax receipt integration is deployed.
- **External calendars:** provider-connection metadata exists; no OAuth clients, subscriptions, secure token vault integration, or continuous Google/Microsoft/Apple sync is deployed.
- **Capacity lottery:** not activated; requires district policy review and an audited, financial-status-neutral selection procedure.

## Database authority

| Source | Role |
| --- | --- |
| `trips` | Authoritative field trip, date, school, destination |
| `field_trip_student_invitations` | Student eligibility for trip display |
| `field_trip_permissions` and `point_submit_field_trip_permission` | **Existing** independent guardian authorization |
| `student_daily_transport_plans` | Existing one-day Point transportation exceptions |
| `student_transport_schedules` | Existing recurring Point transportation schedules |
| `orbit_calendar_events` | New publishable school-event and field-trip calendar projection |
| `orbit_trip_funding_rules` | Deadlines, costs, assistance, donation policy, checkout safety gate |
| `orbit_trip_assistance_requests` | Requester-only confidential assistance requests |
| `orbit_trip_donation_intents` | Parent's optional **unpaid** pledge intent, never a receipt |
| `orbit_trip_payment_ledger` | Server-only, append-only payment evidence, currently empty |
| `orbit_trip_assistance_awards` | Server-only, restricted award bookkeeping |
| `orbit_trip_participation` | Financially neutral parent/Pin/Satellite participation status |

All eight new tables have enabled and forced RLS. The private payment ledger and assistance awards intentionally have **no user-facing SELECT policies**. Anonymous access is revoked. Staff, guardian, and Pin views use tenant + relationship checks.

## Release procedure / FlutterFlow wiring

1. Pull this PR into the operator repository and review all migrations. Migration filenames match versions recorded in the staging `supabase_migrations.schema_migrations`.
2. Connect Point / Pin to `orbit_my_calendar(p_from,p_to)` via authenticated Supabase RPC; display `event_kind=ride_exception` / `ride_schedule` alongside `school_event` and `field_trip`. Never duplicate ride scheduling mutations: retain existing Point transportation RPCs and manifest reconciliation.
3. Connect Satellite and Lead Satellite to `orbit_satellite_calendar(p_from,p_to)`. Teachers see assigned trip records; Central roles see authorized school records. Funding assistance, donor or recipient details are **not** returned.
4. Central staff can create `school_event` drafts and publish events by authorized updates to `orbit_calendar_events.status`. For field trips, create/update through existing Orbit Field/Central trips. The trigger keeps date/destination in sync and creates a **draft**, requiring explicit school publication.
5. Point displays permission and finances as separate actions. Permission goes through existing `point_submit_field_trip_permission`. Optional **Request Assistance** writes to `orbit_trip_assistance_requests` only while school permits requests. Optional **Express Interest in Donating** writes to `orbit_trip_donation_intents`; do not label as `Pay` or `Donation Complete` until payment checkout exists.
6. An authenticated client may request `GET https://ydlwukjzqtssbzirnefs.supabase.co/functions/v1/orbit-calendar-ics?event_id=<uuid>` with `Authorization: Bearer <access JWT>` to receive a one-off .ics file. Do not expose JWTs in URL query strings.
7. Offer persistent provider linking **only after** district opt-in, provider credentials, secret storage, retryable outbox sync, and deletion/revocation flows are independently developed and tested.

## Mandatory staging validation gates before turning on users

- Admin creates and publishes synthetic school event. Parent of enrolled student and Pin can see it; an unrelated parent and unrelated student cannot. Verify Satellite assigned/unassigned teachers.
- Create a synthetic field trip with invitations, permission, date change, cancellation. Confirm source trip changes update the calendar and cancellation notification semantics, and no draft is silently published. Do not modify production.
- Use two staging tenants and unrelated parents to verify cross-tenant denial. Test the *actual* authenticated JWTs, not only database-owner SQL.
- Repeat ride-request One-Day/Weekly/Biweekly transport changes from Point; confirm manifest controls unchanged.
- Confirm donations, requests, students' participation statuses and allocation records cannot be read outside defined scope; no teacher sees donor identities. Check analytics, logs, crash reports and push payloads.
- Validate GET .ics authenticated success and unauthorized 401/404, all-day dates, escaping, calendar import into Google/Apple/Outlook, timezone transitions.
- Payment launch needs a legal/finance owner, district fee-waiver policy, named merchant/payee and signed payment webhook. Add double-entry reconciliation, chargeback/refund processes, idempotency/retries and separate authorized allocation approvals.
- Capacity selection must follow district policy. **Never downgrade a student's chances solely for requesting assistance.** Log capacity, eligibility, random seed/algorithm, decision approvals, notification and appeals, and emergency overrides.
- Pin/parent notification and chaperone calendar UI must pass runnable device E2E, accessibility, offline and push delivery testing before release.
- Run Supabase security/performance advisors; review existing warnings separately from new deliberate no-policy sensitive tables.

## Rollback / recovery

- No production migration has been performed. If an issue is found, stop clients from using the new feature and disable UI flags; do not delete finance/audit records casually.
- Database rollback requires a separately reviewed forward migration preserving audit records and respecting existing trip triggers. Do not automatically DROP the tables or `TRUNCATE` finance/audit records.
- Function deploy may be reverted to an older version after verifying signed session/tenant scope; do not switch `verify_jwt` off.

## Follow-up work not yet delivered

- Actual FlutterFlow screens/widgets and integrations for Point, Pin, Satellite, Lead Satellite.
- Live payment checkout and webhooks, reconciliation, donor receipts, refundable gift rules, district school finance signoff.
- Assistance approval/award endpoints, allocation scheduling and audit UI with segregation of duties.
- Fair capacity lottery and waitlist workflow, pending legal/policy approval.
- OAuth and automatic provider calendar synchronization (Google, Apple, Microsoft).
- Real JWT and device end-to-end tests. Staging currently has **zero** new calendar/financial rows; status checks validate schema and access grants, not actual event/payment flows.
