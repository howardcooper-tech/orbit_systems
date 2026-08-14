# Auth tenant hook — Dashboard registration

SQL in `supabase/migrations/20260814000000_phase_3e_auth_tenant_jwt_hook.sql` **creates** the function. It does **not** turn the hook on for a hosted Supabase project.

This repo’s `supabase/config.toml` has `project_id = "YOUR_PROJECT_REF"` (unlinked). Hosted Auth Hook enablement is **Dashboard-only** until the project is linked and config is applied.

## Enable (hosted)

1. Apply the Phase 3e migration in a **non-production** SQL Editor first (postgres role). Confirm `COMMIT`.
2. Run `supabase/AUTH_TENANT_HOOK_VALIDATE.sql` (read-only).
3. Supabase Dashboard → **Authentication** → **Hooks** (sometimes **Auth Hooks**).
4. Select **Custom Access Token**.
5. Enable it.
6. Type: **Postgres Function**.
7. Schema: `public`.
8. Function: `custom_access_token_hook`.
9. Save.

Required permission (already in the migration): `supabase_auth_admin` EXECUTE on `public.custom_access_token_hook(jsonb)`.

## Expected claim

After the next sign-in or token refresh, the access token payload must contain:

```json
"tenant_id": "<districts.id UUID>"
```

Phase 3c reads exactly `auth.jwt() ->> 'tenant_id'`. A copy may also appear under `app_metadata.tenant_id`; the wall does not use that path.

## Expected behavior

| Resolver result | JWT | RLS |
|-----------------|-----|-----|
| Exactly one `districts.id` | `tenant_id` set | Tenant rows visible (plus existing role policies) |
| None | claim omitted | Authenticated sees no tenant rows |
| Two or more districts | claim omitted | Same fail-closed |

Hook errors are caught and the original event is returned (still no tenant claim). Do not use that as a reason to disable the hook.

## Local CLI (optional)

`supabase/config.toml` includes:

```toml
[auth.hook.custom_access_token]
enabled = true
uri = "pg-functions://postgres/public/custom_access_token_hook"
```

This applies to `supabase start` / linked CLI. It does **not** replace the hosted Dashboard toggle.

## Rollback

1. Dashboard → Authentication → Hooks → Custom Access Token → **disable**.
2. Existing sessions keep their current JWT until expiry/refresh.
3. Do **not** drop `custom_access_token_hook` unless you also disable the hook; a enabled hook pointing at a missing function can block token issuance.
4. Do **not** drop or alter `public.jwt_tenant_id()` (Phase 3c).

After disable, new tokens will lack `tenant_id` and the Duval Wall will deny authenticated table access again.
