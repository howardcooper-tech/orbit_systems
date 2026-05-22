-- ORBIT PHASE 1 — 01: Extensions
-- Run first. Requires Supabase default auth schema.

BEGIN;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;

COMMIT;
