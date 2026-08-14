# Auth tenant JWT hook — test plan

Do **not** run these against production first. Use staging. After Phase 3e SQL is applied and the Dashboard hook is enabled, sign in again (or refresh the session) so a new access token is minted.

Decode the access token (JWT payload) only on your machine. Do not paste live tokens into tickets.

Prerequisite: `public.jwt_tenant_id()`, `get_my_role()`, `get_my_district()`, and `verify_student_pin()` are unchanged.

---

## Test 1 — Valid staff

**Setup:** `staff_profiles.id` = auth user, `is_active`, `archived_at` null, `district_id` = a real `districts.id`. No parent/secondary/node links to a different district.

**Expect:** Access token `"tenant_id"` equals that `districts.id`.

**SQL check (as postgres, after login is not required):**

```sql
SELECT id, district_id, public.resolve_orbit_tenant_id(id)
FROM public.staff_profiles
WHERE id = '<staff-uuid>';
```

`resolve_orbit_tenant_id` and `district_id` must match.

---

## Test 2 — Valid parent

**Setup:** `parents.id` = auth user. At least one `student_guardians` row to a non-archived student whose `schools.district_id` is a single district. No staff `district_id` pointing elsewhere.

**Expect:** `"tenant_id"` equals that `schools.district_id`.

```sql
SELECT public.resolve_orbit_tenant_id('<parent-uuid>');
```

---

## Test 3 — No tenant

**Setup:** Auth user with no staff `district_id`, no guardian students, no secondary authorizations, no chaperone `node_id` rows.

**Expect:** Resolver returns NULL. JWT has **no usable** `tenant_id`. Authenticated `SELECT` on `trips` / `students` returns zero rows (Duval Wall). Login itself may still succeed.

---

## Test 4 — Multiple tenant conflict

**Setup:** Same `auth.users.id` as staff in district A **and** parent of a student in district B.

**Expect:** `resolve_orbit_tenant_id` is NULL. JWT omits `tenant_id`. No silent pick of A or B.

```sql
-- Should return the user_id with tenant_count > 1
-- (query D in supabase/AUTH_TENANT_HOOK_VALIDATE.sql)
```

---

## Test 5 — RLS (two districts)

Use two authenticated sessions (not service_role).

Tenant A user:

- can `SELECT` rows where `tenant_id` = A
- cannot `SELECT` Tenant B rows
- cannot `INSERT` a row with `tenant_id` = B
- cannot `UPDATE` a row to set `tenant_id` = B (`duval_stamp_tenant_id` immutability)

Do not test as the SQL Editor postgres role (BYPASSRLS).

---

## Test 6 — Existing application behavior

As an authenticated staff JWT **with** `tenant_id`:

```sql
SELECT public.get_my_role();
SELECT public.get_my_district();
SELECT public.jwt_tenant_id();
SELECT public.verify_student_pin('<student-uuid>', '<pin>');
```

- `get_my_role` / `get_my_district` still read `staff_profiles` (unchanged).
- `jwt_tenant_id()` equals the JWT `tenant_id` and `get_my_district()` when the staff district is that tenant.
- `verify_student_pin` still returns boolean only (no PIN echo).

---

## Pass / fail

| Test | Pass |
|------|------|
| 1 Staff | JWT tenant_id = staff_profiles.district_id |
| 2 Parent | JWT tenant_id = school district of linked students |
| 3 None | No tenant_id claim; RLS empty |
| 4 Conflict | No tenant_id claim |
| 5 RLS | Cross-tenant denied |
| 6 Compat | Four functions still behave as before |
