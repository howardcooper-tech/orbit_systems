-- ============================================================================
-- ORBIT STAGING SWEEP — Full public schema reset
-- ============================================================================
--
-- *** STAGING / DEV ONLY — DESTROYS ALL DATA IN public + archive ***
--
-- Does NOT delete auth.users (login accounts remain).
-- Does remove all public tables, views, functions, triggers, types, and RLS.
--
-- Run this ONCE on an empty slate before Phase 1 (01_extensions.sql … 12_indexes.sql).
--
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Detach Supabase Realtime (avoids orphan publication errors)
-- --------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT pubname, schemaname, tablename
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
    LOOP
        EXECUTE format(
            'ALTER PUBLICATION supabase_realtime DROP TABLE %I.%I',
            r.schemaname,
            r.tablename
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Realtime drop skipped for %.%: %', r.schemaname, r.tablename, SQLERRM;
    END LOOP;
END $$;

-- --------------------------------------------------------------------------
-- 2. Remove auth hooks that point at public (survive public CASCADE)
-- --------------------------------------------------------------------------
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'students'
    ) THEN
        EXECUTE 'DROP TRIGGER IF EXISTS on_student_graduation ON public.students';
    END IF;
END $$;

-- --------------------------------------------------------------------------
-- 3. Drop Orbit cold storage + all public objects
-- --------------------------------------------------------------------------
DROP SCHEMA IF EXISTS archive CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;

-- --------------------------------------------------------------------------
-- 4. Recreate public with Supabase-expected grants
-- --------------------------------------------------------------------------
CREATE SCHEMA public;

GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT ALL ON SCHEMA public TO postgres, service_role;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO postgres, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;

COMMIT;

-- --------------------------------------------------------------------------
-- 5. Post-sweep verification (run separately; should return 0 rows)
-- --------------------------------------------------------------------------
-- SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';
-- SELECT nspname FROM pg_namespace WHERE nspname = 'archive';
