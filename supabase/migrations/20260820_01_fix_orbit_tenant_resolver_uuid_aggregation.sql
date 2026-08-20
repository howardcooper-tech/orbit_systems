-- Verified live on Orbit Systems Staging (ydlwukjzqtssbzirnefs).
-- Replaces invalid MIN(uuid) aggregation with a distinct UUID candidate set.

CREATE OR REPLACE FUNCTION public.resolve_orbit_tenant_id(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    ), distinct_candidates AS (
        SELECT DISTINCT tenant_id
        FROM candidates
        WHERE tenant_id IS NOT NULL
    )
    SELECT COUNT(*), (ARRAY_AGG(tenant_id))[1]
    INTO v_count, v_tenant
    FROM distinct_candidates;

    IF v_count = 1 THEN
        RETURN v_tenant;
    END IF;

    RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_orbit_tenant_id(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_orbit_tenant_id(uuid) TO supabase_auth_admin;
