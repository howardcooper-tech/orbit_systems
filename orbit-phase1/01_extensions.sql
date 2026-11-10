-- ORBIT PHASE 1 — 01: Extensions
-- Run first. Requires Supabase default auth schema.

BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;

-- uuid-ossp stays available for uuid_generate_v4() used by Phase 1.
-- PostGIS must live in extensions, not public. Geography and geometry
-- columns resolve only when later scripts include extensions on search_path.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

COMMIT;
