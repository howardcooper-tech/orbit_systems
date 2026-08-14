-- Orbit Systems — read-only validation for Phase 3e Auth tenant hook.
-- Do NOT apply via supabase db push. Run in SQL Editor as postgres after 3e.
-- Makes no INSERT/UPDATE/DELETE/DDL.

-- A. Functions exist with expected signatures
SELECT
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS args,
    p.prosecdef AS security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
      'custom_access_token_hook',
      'resolve_orbit_tenant_id',
      'jwt_tenant_id',
      'get_my_role',
      'get_my_district',
      'verify_student_pin'
  )
ORDER BY p.proname;

-- B. Execute grants on the hook (expect supabase_auth_admin only among app roles)
SELECT
    p.proname,
    r.rolname,
    has_function_privilege(r.oid, p.oid, 'EXECUTE') AS can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN pg_roles r
WHERE n.nspname = 'public'
  AND p.proname IN ('custom_access_token_hook', 'resolve_orbit_tenant_id')
  AND r.rolname IN (
      'anon',
      'authenticated',
      'public',
      'supabase_auth_admin',
      'service_role',
      'postgres'
  )
ORDER BY p.proname, r.rolname;

-- C. Tenant mapping for linked users (expected single district)
SELECT
    u.id AS user_id,
    public.resolve_orbit_tenant_id(u.id) AS resolved_tenant_id,
    sp.district_id AS staff_district_id,
    sp.role AS staff_role
FROM auth.users u
LEFT JOIN public.staff_profiles sp ON sp.id = u.id
WHERE public.resolve_orbit_tenant_id(u.id) IS NOT NULL
ORDER BY u.created_at DESC
LIMIT 50;

-- D. Ambiguous users (2+ distinct district ids across staff/parent/secondary/node)
WITH staff_t AS (
    SELECT sp.id AS user_id, sp.district_id AS tenant_id
    FROM public.staff_profiles sp
    WHERE sp.is_active AND sp.archived_at IS NULL AND sp.district_id IS NOT NULL
),
parent_t AS (
    SELECT sg.parent_id AS user_id, sch.district_id AS tenant_id
    FROM public.student_guardians sg
    JOIN public.students s ON s.id = sg.student_id
    JOIN public.schools sch ON sch.id = s.school_id
    WHERE s.archived_at IS NULL AND sch.district_id IS NOT NULL
),
secondary_t AS (
    SELECT ssa.secondary_id AS user_id, sch.district_id AS tenant_id
    FROM public.student_secondary_authorizations ssa
    JOIN public.students s ON s.id = ssa.student_id
    JOIN public.schools sch ON sch.id = s.school_id
    WHERE s.archived_at IS NULL AND sch.district_id IS NOT NULL
),
node_t AS (
    SELECT g.node_id AS user_id, t.district_id AS tenant_id
    FROM public.trip_chaperone_groups g
    JOIN public.trips t ON t.id = g.trip_id
    WHERE g.node_id IS NOT NULL AND t.district_id IS NOT NULL
),
all_t AS (
    SELECT * FROM staff_t
    UNION ALL SELECT * FROM parent_t
    UNION ALL SELECT * FROM secondary_t
    UNION ALL SELECT * FROM node_t
)
SELECT
    user_id,
    COUNT(DISTINCT tenant_id) AS tenant_count,
    array_agg(DISTINCT tenant_id) AS tenant_ids
FROM all_t
GROUP BY user_id
HAVING COUNT(DISTINCT tenant_id) > 1;

-- E. Orphaned auth users (login exists, resolver returns NULL)
SELECT
    u.id,
    u.email,
    (sp.id IS NOT NULL) AS has_staff_profile,
    (p.id IS NOT NULL) AS has_parent_row,
    (gp.id IS NOT NULL) AS has_guardian_profile,
    (sap.id IS NOT NULL) AS has_secondary_profile
FROM auth.users u
LEFT JOIN public.staff_profiles sp ON sp.id = u.id
LEFT JOIN public.parents p ON p.id = u.id
LEFT JOIN public.guardian_profiles gp ON gp.id = u.id
LEFT JOIN public.secondary_authorized_profiles sap ON sap.id = u.id
WHERE public.resolve_orbit_tenant_id(u.id) IS NULL
ORDER BY u.created_at DESC
LIMIT 100;

-- F. Duval Wall helper unchanged (must still read JWT tenant_id only)
SELECT pg_get_functiondef('public.jwt_tenant_id()'::regprocedure) AS jwt_tenant_id_def;
