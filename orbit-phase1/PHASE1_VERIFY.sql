-- Run after Phase 1 (01–12) to confirm schema integrity

-- Table count (expect ~35+ base tables)
SELECT count(*) AS public_base_tables
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

-- Audit protection on manifest
SELECT c.conname, c.confdeltype AS delete_action
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
  AND t.relname = 'trip_manifest'
  AND c.conname = 'trip_manifest_trip_id_fkey';
-- delete_action must be 'r' (RESTRICT)

-- SIS / BLE split exists
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('student_sis_enrollment', 'students')
ORDER BY 1;

-- No triggers yet (Phase 3)
SELECT count(*) AS trigger_count
FROM pg_trigger tg
JOIN pg_class c ON c.oid = tg.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND NOT tg.tgisinternal;

-- RLS should be OFF until Phase 3
SELECT relname, relrowsecurity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY relname;
