-- Phase 3 — Enable RLS on all public base tables (Orbit-owned only)

BEGIN;

DO $$
DECLARE
    t TEXT;
    denylist TEXT[] := ARRAY['spatial_ref_sys'];  -- PostGIS extension; not owned by postgres
BEGIN
    FOR t IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind = 'r'
          AND pg_get_userbyid(c.relowner) = current_user
    LOOP
        IF t = ANY (denylist) THEN
            CONTINUE;
        END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

COMMIT;
