-- =============================================================================
-- Orbit Systems — Phase 3e: Custom Access Token Hook (JWT tenant_id)
-- =============================================================================
-- Apply AFTER Phase 3c (Duval Wall). Idempotent. Do NOT run against production
-- until reviewed. This file does not DROP objects, policies, or auth records.
--
-- Why: Phase 3c RLS is restrictive:
--   tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
-- Missing claim => authenticated users see zero rows (fail closed).
--
-- Tenant source (exactly one districts.id, else NULL):
--   1. staff_profiles.district_id (staff_profiles.id = auth.users.id)
--   2. parents via student_guardians → students → schools.district_id
--   3. secondary_authorized_profiles via student_secondary_authorizations
--   4. guardian Nodes via trip_chaperone_groups.node_id → trips.district_id
--
-- Fail closed: 0 tenants or 2+ distinct tenants => do not set tenant_id.
-- Does not rewrite Phase 3c functions or RLS policies.
--
-- Registration: hosted Auth Hooks are enabled in the Dashboard (see
-- docs/AUTH_TENANT_HOOK_DEPLOY.md). Local CLI uses supabase/config.toml.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Resolver: one UUID or NULL. Not granted to anon/authenticated.
-- SECURITY DEFINER: Auth mints tokens as supabase_auth_admin, which is subject
-- to FORCE RLS and would otherwise see zero profile rows during the hook.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_orbit_tenant_id(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count integer := 0;
    v_tenant uuid;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN NULL;
    END IF;

    WITH candidates AS (
        SELECT sp.district_id AS tenant_id
        FROM public.staff_profiles sp
        WHERE sp.id = p_user_id
          AND sp.is_active IS TRUE
          AND sp.archived_at IS NULL
          AND sp.district_id IS NOT NULL

        UNION

        SELECT sch.district_id
        FROM public.student_guardians sg
        JOIN public.students s ON s.id = sg.student_id
        JOIN public.schools sch ON sch.id = s.school_id
        WHERE sg.parent_id = p_user_id
          AND s.archived_at IS NULL
          AND sch.district_id IS NOT NULL

        UNION

        SELECT sch.district_id
        FROM public.student_secondary_authorizations ssa
        JOIN public.students s ON s.id = ssa.student_id
        JOIN public.schools sch ON sch.id = s.school_id
        WHERE ssa.secondary_id = p_user_id
          AND s.archived_at IS NULL
          AND sch.district_id IS NOT NULL

        UNION

        SELECT t.district_id
        FROM public.trip_chaperone_groups g
        JOIN public.trips t ON t.id = g.trip_id
        WHERE g.node_id = p_user_id
          AND t.district_id IS NOT NULL
    )
    SELECT COUNT(DISTINCT c.tenant_id), MIN(c.tenant_id)
    INTO v_count, v_tenant
    FROM candidates c
    WHERE c.tenant_id IS NOT NULL;

    IF v_count = 1 THEN
        RETURN v_tenant;
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.resolve_orbit_tenant_id(uuid) IS
    'Orbit tenant resolver for the Auth hook. Returns districts.id when exactly one tenant is proven; NULL if none or conflicting (fail closed). Used by custom_access_token_hook. Not a client RPC.';

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    claims jsonb;
    app_meta jsonb;
    uid uuid;
    tenant uuid;
BEGIN
    IF event IS NULL THEN
        RETURN NULL;
    END IF;

    BEGIN
        uid := NULLIF(btrim(event ->> 'user_id'), '')::uuid;
    EXCEPTION
        WHEN others THEN
            RETURN event;
    END;

    claims := COALESCE(event -> 'claims', '{}'::jsonb);
    tenant := public.resolve_orbit_tenant_id(uid);

    IF tenant IS NOT NULL THEN
        -- Top-level claim: required by public.jwt_tenant_id() / Duval Wall.
        claims := jsonb_set(claims, '{tenant_id}', to_jsonb(tenant::text), true);
        -- Nested copy only; does not replace other app_metadata keys.
        app_meta := COALESCE(claims -> 'app_metadata', '{}'::jsonb);
        IF jsonb_typeof(app_meta) IS DISTINCT FROM 'object' THEN
            app_meta := '{}'::jsonb;
        END IF;
        app_meta := jsonb_set(app_meta, '{tenant_id}', to_jsonb(tenant::text), true);
        claims := jsonb_set(claims, '{app_metadata}', app_meta, true);
    END IF;

    event := jsonb_set(COALESCE(event, '{}'::jsonb), '{claims}', claims, true);
    RETURN event;
EXCEPTION
    WHEN others THEN
        RAISE WARNING 'ORBIT_AUTH_HOOK failed closed: %', SQLERRM;
        RETURN event;
END;
$$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
    'Supabase Custom Access Token Hook. Sets JWT tenant_id = districts.id for Duval Wall (auth.jwt() ->> tenant_id). Preserves existing claims. Omits tenant_id when unresolved or ambiguous. Invoked only by supabase_auth_admin.';

REVOKE ALL ON FUNCTION public.resolve_orbit_tenant_id(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_orbit_tenant_id(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.resolve_orbit_tenant_id(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.resolve_orbit_tenant_id(uuid) TO supabase_auth_admin;

COMMIT;
