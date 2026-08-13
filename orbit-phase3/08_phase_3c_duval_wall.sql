-- =============================================================================
-- Orbit Systems — Phase 3c: The Duval Wall & WORM Ledger
-- =============================================================================
-- Apply AFTER Phase 3 + Phase 3b (verify_student_pin).
-- Idempotent. Run as postgres / service role (SQL editor or orbit-tools runner).
--
-- Closes the open perimeter:
--   1. tenant_id on every Orbit core table (districts.id is the tenant).
--   2. ENABLE + FORCE ROW LEVEL SECURITY on all Orbit-owned public/archive tables.
--   3. Baseline DENY ALL for anon.
--   4. Restrictive tenant isolation:
--        tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
--      AND'd with existing Phase 3 permissive role policies.
--   5. audit_worm_ledger: INSERT-only. UPDATE / DELETE / TRUNCATE raise.
--   6. trip_manifest mutations are auto-copied onto the WORM ledger.
--
-- AUTH REQUIREMENT (fail-closed):
--   Every authenticated JWT MUST carry claim tenant_id = districts.id
--   (custom access token hook or auth.users.raw_app_meta_data.tenant_id
--    surfaced as a top-level JWT claim named tenant_id).
--   Missing / invalid tenant_id => no row access for authenticated.
--   service_role keeps BYPASSRLS for Edge Functions.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.jwt_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT NULLIF(trim(auth.jwt() ->> 'tenant_id'), '')::uuid
$$;

COMMENT ON FUNCTION public.jwt_tenant_id() IS
    'Duval Wall tenant key. Reads auth.jwt() ->> tenant_id. Fail-closed on NULL.';

REVOKE ALL ON FUNCTION public.jwt_tenant_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jwt_tenant_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.jwt_tenant_id() TO service_role;

-- Stamp tenant_id on INSERT; freeze it on UPDATE. Authenticated cannot cross tenants.
CREATE OR REPLACE FUNCTION public.duval_stamp_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_jwt uuid;
BEGIN
    v_jwt := public.jwt_tenant_id();

    IF TG_OP = 'INSERT' THEN
        IF NEW.tenant_id IS NULL THEN
            IF TG_TABLE_NAME = 'districts' AND NEW.id IS NOT NULL THEN
                NEW.tenant_id := NEW.id;
            ELSIF to_jsonb(NEW) ? 'district_id' AND (to_jsonb(NEW) ->> 'district_id') IS NOT NULL THEN
                NEW.tenant_id := (to_jsonb(NEW) ->> 'district_id')::uuid;
            ELSE
                NEW.tenant_id := v_jwt;
            END IF;
        END IF;

        IF current_setting('role', true) = 'authenticated' THEN
            IF v_jwt IS NULL THEN
                RAISE EXCEPTION 'DUVAL_WALL: JWT tenant_id claim is required'
                    USING ERRCODE = '42501';
            END IF;
            IF NEW.tenant_id IS DISTINCT FROM v_jwt THEN
                RAISE EXCEPTION 'DUVAL_WALL: tenant_id does not match JWT tenant_id'
                    USING ERRCODE = '42501';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
            RAISE EXCEPTION 'DUVAL_WALL: tenant_id is immutable'
                USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.deny_worm_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    RAISE EXCEPTION 'WORM_VIOLATION: audit_worm_ledger is write-once (no %)', TG_OP
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE OR REPLACE FUNCTION public.worm_log_trip_manifest()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant uuid;
    v_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tenant := OLD.tenant_id;
        v_id := OLD.id;
    ELSE
        v_tenant := NEW.tenant_id;
        v_id := NEW.id;
    END IF;

    IF v_tenant IS NULL THEN
        SELECT t.district_id INTO v_tenant
        FROM public.trips t
        WHERE t.id = COALESCE(NEW.trip_id, OLD.trip_id);
    END IF;

    INSERT INTO public.audit_worm_ledger (
        tenant_id,
        actor_id,
        action_type,
        source_table,
        source_record_id,
        old_row,
        new_row,
        jwt_tenant_id
    )
    VALUES (
        v_tenant,
        auth.uid(),
        TG_OP,
        'trip_manifest',
        v_id,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
        public.jwt_tenant_id()
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.duval_stamp_tenant_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deny_worm_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.worm_log_trip_manifest() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 1. tenant_id columns on all core tables
-- -----------------------------------------------------------------------------

ALTER TABLE IF EXISTS public.districts ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.contractors ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.schools ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.staff_profiles ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.parents ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.guardian_profiles ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.student_sis_enrollment ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.students ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.student_guardians ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.student_device_authorizations ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.buses ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.bus_telemetry_logs ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trips ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trip_manifest ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.bus_trip_handshakes ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.audit_logs ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.bus_inspections ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.maintenance_work_orders ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.comms_channels ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.comms_messages ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.route_waypoints ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trip_active_mesh ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.student_scan_events ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.emergency_flares ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.incident_dispatch_logs ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.routes ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.route_stops ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.field_trip_venues ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trip_chaperone_groups ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.field_trip_checkouts ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trip_chaperone_handshakes ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.custody_waiver_logs ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.secondary_authorized_profiles ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.student_secondary_authorizations ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.halo_sessions ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.halo_manifest_snapshots ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.rescue_handshakes ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.outbound_alerts ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.drone_assets ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE IF EXISTS public.trusted_hardware ADD COLUMN IF NOT EXISTS tenant_id uuid;

-- -----------------------------------------------------------------------------
-- 2. Backfill tenant_id from existing district / school / trip / bus graph
-- -----------------------------------------------------------------------------

UPDATE public.districts SET tenant_id = id WHERE tenant_id IS NULL;

UPDATE public.contractors SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.schools SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.staff_profiles SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.buses SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.trips SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.comms_channels SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.emergency_flares SET tenant_id = district_id WHERE tenant_id IS NULL;
UPDATE public.drone_assets SET tenant_id = district_id WHERE tenant_id IS NULL;

UPDATE public.students s
SET tenant_id = sch.district_id
FROM public.schools sch
WHERE sch.id = s.school_id
  AND s.tenant_id IS NULL;

UPDATE public.student_sis_enrollment e
SET tenant_id = sch.district_id
FROM public.schools sch
WHERE sch.id = e.school_id
  AND e.tenant_id IS NULL;

UPDATE public.student_guardians g
SET tenant_id = s.tenant_id
FROM public.students s
WHERE s.id = g.student_id
  AND g.tenant_id IS NULL;

UPDATE public.student_device_authorizations a
SET tenant_id = s.tenant_id
FROM public.students s
WHERE s.id = a.student_id
  AND a.tenant_id IS NULL;

UPDATE public.parents p
SET tenant_id = x.tenant_id
FROM (
    SELECT DISTINCT ON (sg.parent_id) sg.parent_id, s.tenant_id
    FROM public.student_guardians sg
    JOIN public.students s ON s.id = sg.student_id
    WHERE s.tenant_id IS NOT NULL
    ORDER BY sg.parent_id, s.tenant_id
) x
WHERE p.id = x.parent_id
  AND p.tenant_id IS NULL;

UPDATE public.guardian_profiles gp
SET tenant_id = COALESCE(p.tenant_id, sp.tenant_id)
FROM public.guardian_profiles g
LEFT JOIN public.parents p ON p.id = g.id
LEFT JOIN public.staff_profiles sp ON sp.id = g.id
WHERE gp.id = g.id
  AND gp.tenant_id IS NULL
  AND COALESCE(p.tenant_id, sp.tenant_id) IS NOT NULL;

UPDATE public.bus_telemetry_logs l
SET tenant_id = b.tenant_id
FROM public.buses b
WHERE b.id = l.bus_id
  AND l.tenant_id IS NULL;

UPDATE public.trip_manifest m
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = m.trip_id
  AND m.tenant_id IS NULL;

UPDATE public.bus_trip_handshakes h
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = h.trip_id
  AND h.tenant_id IS NULL;

UPDATE public.bus_inspections i
SET tenant_id = b.tenant_id
FROM public.buses b
WHERE b.id = i.bus_id
  AND i.tenant_id IS NULL;

UPDATE public.maintenance_work_orders w
SET tenant_id = b.tenant_id
FROM public.buses b
WHERE b.id = w.bus_id
  AND w.tenant_id IS NULL;

UPDATE public.comms_messages msg
SET tenant_id = ch.tenant_id
FROM public.comms_channels ch
WHERE ch.id = msg.channel_id
  AND msg.tenant_id IS NULL;

UPDATE public.route_waypoints rw
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = rw.trip_id
  AND rw.tenant_id IS NULL;

UPDATE public.trip_active_mesh mesh
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = mesh.trip_id
  AND mesh.tenant_id IS NULL;

UPDATE public.student_scan_events sc
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = sc.trip_id
  AND sc.tenant_id IS NULL;

UPDATE public.incident_dispatch_logs d
SET tenant_id = f.tenant_id
FROM public.emergency_flares f
WHERE f.id = d.flare_id
  AND d.tenant_id IS NULL;

UPDATE public.routes r
SET tenant_id = sch.district_id
FROM public.schools sch
WHERE sch.id = r.school_id
  AND r.tenant_id IS NULL;

UPDATE public.route_stops rs
SET tenant_id = r.tenant_id
FROM public.routes r
WHERE r.id = rs.route_id
  AND rs.tenant_id IS NULL;

UPDATE public.field_trip_venues v
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.venue_id = v.id
  AND v.tenant_id IS NULL;

UPDATE public.trip_chaperone_groups g
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = g.trip_id
  AND g.tenant_id IS NULL;

UPDATE public.field_trip_checkouts c
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = c.trip_id
  AND c.tenant_id IS NULL;

UPDATE public.trip_chaperone_handshakes h
SET tenant_id = t.tenant_id
FROM public.trips t
WHERE t.id = h.trip_id
  AND h.tenant_id IS NULL;

UPDATE public.custody_waiver_logs w
SET tenant_id = s.tenant_id
FROM public.students s
WHERE s.id = w.student_id
  AND w.tenant_id IS NULL;

UPDATE public.student_secondary_authorizations a
SET tenant_id = s.tenant_id
FROM public.students s
WHERE s.id = a.student_id
  AND a.tenant_id IS NULL;

UPDATE public.secondary_authorized_profiles p
SET tenant_id = x.tenant_id
FROM (
    SELECT DISTINCT ON (a.secondary_id) a.secondary_id, a.tenant_id
    FROM public.student_secondary_authorizations a
    WHERE a.tenant_id IS NOT NULL
    ORDER BY a.secondary_id, a.tenant_id
) x
WHERE p.id = x.secondary_id
  AND p.tenant_id IS NULL;

UPDATE public.halo_sessions hs
SET tenant_id = COALESCE(f.tenant_id, b.tenant_id)
FROM public.halo_sessions h
LEFT JOIN public.emergency_flares f ON f.id = h.flare_id
LEFT JOIN public.buses b ON b.id = h.bus_id
WHERE hs.id = h.id
  AND hs.tenant_id IS NULL
  AND COALESCE(f.tenant_id, b.tenant_id) IS NOT NULL;

UPDATE public.halo_manifest_snapshots snap
SET tenant_id = COALESCE(hs.tenant_id, s.tenant_id)
FROM public.halo_sessions hs, public.students s
WHERE hs.id = snap.halo_session_id
  AND s.id = snap.student_id
  AND snap.tenant_id IS NULL;

UPDATE public.rescue_handshakes rh
SET tenant_id = hs.tenant_id
FROM public.halo_sessions hs
WHERE hs.id = rh.halo_session_id
  AND rh.tenant_id IS NULL;

UPDATE public.outbound_alerts a
SET tenant_id = sp.tenant_id
FROM public.staff_profiles sp
WHERE sp.id = a.recipient_id
  AND a.tenant_id IS NULL;

UPDATE public.outbound_alerts a
SET tenant_id = p.tenant_id
FROM public.parents p
WHERE p.id = a.recipient_id
  AND a.tenant_id IS NULL;

UPDATE public.trusted_hardware th
SET tenant_id = b.tenant_id
FROM public.buses b
WHERE b.id = th.assigned_bus_id
  AND th.tenant_id IS NULL;

-- -----------------------------------------------------------------------------
-- 3. WORM ledger (create after tenant_id exists on districts for the FK)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.audit_worm_ledger (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id uuid REFERENCES public.districts(id) ON DELETE RESTRICT,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    action_type text NOT NULL CHECK (action_type IN ('INSERT', 'UPDATE', 'DELETE')),
    source_table text NOT NULL,
    source_record_id uuid,
    old_row jsonb,
    new_row jsonb,
    jwt_tenant_id uuid,
    CONSTRAINT audit_worm_ledger_source_chk CHECK (char_length(source_table) > 0)
);

COMMENT ON TABLE public.audit_worm_ledger IS
    'Immutable liability shield. INSERT-only. Engine raises on UPDATE/DELETE/TRUNCATE.';

CREATE INDEX IF NOT EXISTS audit_worm_ledger_tenant_occurred_idx
    ON public.audit_worm_ledger (tenant_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS audit_worm_ledger_source_idx
    ON public.audit_worm_ledger (source_table, source_record_id);

DROP TRIGGER IF EXISTS trig_worm_deny_update_delete ON public.audit_worm_ledger;
CREATE TRIGGER trig_worm_deny_update_delete
    BEFORE UPDATE OR DELETE ON public.audit_worm_ledger
    FOR EACH ROW
    EXECUTE FUNCTION public.deny_worm_mutation();

DROP TRIGGER IF EXISTS trig_worm_deny_truncate ON public.audit_worm_ledger;
CREATE TRIGGER trig_worm_deny_truncate
    BEFORE TRUNCATE ON public.audit_worm_ledger
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.deny_worm_mutation();

DROP TRIGGER IF EXISTS trig_worm_log_trip_manifest ON public.trip_manifest;
CREATE TRIGGER trig_worm_log_trip_manifest
    AFTER INSERT OR UPDATE OR DELETE ON public.trip_manifest
    FOR EACH ROW
    EXECUTE FUNCTION public.worm_log_trip_manifest();

-- -----------------------------------------------------------------------------
-- 4. Tenant indexes, stamp triggers, ENABLE + FORCE RLS, deny-all + tenant wall
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    r record;
    denylist text[] := ARRAY['spatial_ref_sys'];
BEGIN
    FOR r IN
        SELECT n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('public', 'archive')
          AND c.relkind = 'r'
          AND NOT (n.nspname = 'public' AND c.relname = ANY (denylist))
          AND EXISTS (
              SELECT 1
              FROM information_schema.columns col
              WHERE col.table_schema = n.nspname
                AND col.table_name = c.relname
                AND col.column_name = 'tenant_id'
          )
    LOOP
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I.%I (tenant_id)',
            r.table_name || '_tenant_id_idx',
            r.schema_name,
            r.table_name
        );

        EXECUTE format(
            'DROP TRIGGER IF EXISTS trig_duval_stamp_tenant ON %I.%I',
            r.schema_name,
            r.table_name
        );

        -- Ledger rows are stamped by worm_log_trip_manifest / service_role inserts.
        IF NOT (r.schema_name = 'public' AND r.table_name = 'audit_worm_ledger') THEN
            EXECUTE format(
                'CREATE TRIGGER trig_duval_stamp_tenant
                 BEFORE INSERT OR UPDATE ON %I.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.duval_stamp_tenant_id()',
                r.schema_name,
                r.table_name
            );
        END IF;

        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.schema_name, r.table_name);
        EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', r.schema_name, r.table_name);

        -- Baseline DENY ALL for anonymous. RLS already defaults to deny when no
        -- permissive policy matches; this makes the closed door explicit.
        EXECUTE format('DROP POLICY IF EXISTS duval_deny_all ON %I.%I', r.schema_name, r.table_name);
        EXECUTE format(
            'CREATE POLICY duval_deny_all ON %I.%I
             AS RESTRICTIVE
             FOR ALL
             TO anon
             USING (false)
             WITH CHECK (false)',
            r.schema_name,
            r.table_name
        );

        -- Restrictive AND-wall. Permissive Phase 3 role policies still apply,
        -- but cannot leak across tenants.
        EXECUTE format('DROP POLICY IF EXISTS duval_tenant_isolation ON %I.%I', r.schema_name, r.table_name);
        EXECUTE format(
            'CREATE POLICY duval_tenant_isolation ON %I.%I
             AS RESTRICTIVE
             FOR ALL
             TO authenticated
             USING (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)
             WITH CHECK (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)',
            r.schema_name,
            r.table_name
        );
    END LOOP;
END $$;

-- Tables that still lack tenant_id (should be none except PostGIS): lock them shut.
DO $$
DECLARE
    r record;
    denylist text[] := ARRAY['spatial_ref_sys'];
BEGIN
    FOR r IN
        SELECT n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('public', 'archive')
          AND c.relkind = 'r'
          AND NOT (n.nspname = 'public' AND c.relname = ANY (denylist))
          AND NOT EXISTS (
              SELECT 1
              FROM information_schema.columns col
              WHERE col.table_schema = n.nspname
                AND col.table_name = c.relname
                AND col.column_name = 'tenant_id'
          )
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.schema_name, r.table_name);
        EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', r.schema_name, r.table_name);
        EXECUTE format('DROP POLICY IF EXISTS duval_deny_all ON %I.%I', r.schema_name, r.table_name);
        EXECUTE format(
            'CREATE POLICY duval_deny_all ON %I.%I
             AS RESTRICTIVE
             FOR ALL
             TO public
             USING (false)
             WITH CHECK (false)',
            r.schema_name,
            r.table_name
        );
    END LOOP;
END $$;

-- Archive copies: add tenant_id if the LIKE snapshot predates this migration.
DO $$
DECLARE
    r record;
BEGIN
    IF to_regnamespace('archive') IS NULL THEN
        RETURN;
    END IF;

    FOR r IN
        SELECT c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'archive'
          AND c.relkind = 'r'
    LOOP
        EXECUTE format(
            'ALTER TABLE archive.%I ADD COLUMN IF NOT EXISTS tenant_id uuid',
            r.table_name
        );
        EXECUTE format('ALTER TABLE archive.%I ENABLE ROW LEVEL SECURITY', r.table_name);
        EXECUTE format('ALTER TABLE archive.%I FORCE ROW LEVEL SECURITY', r.table_name);
        EXECUTE format('DROP POLICY IF EXISTS duval_deny_all ON archive.%I', r.table_name);
        EXECUTE format(
            'CREATE POLICY duval_deny_all ON archive.%I
             AS RESTRICTIVE FOR ALL TO anon
             USING (false) WITH CHECK (false)',
            r.table_name
        );
        EXECUTE format('DROP POLICY IF EXISTS duval_tenant_isolation ON archive.%I', r.table_name);
        EXECUTE format(
            'CREATE POLICY duval_tenant_isolation ON archive.%I
             AS RESTRICTIVE FOR ALL TO authenticated
             USING (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)
             WITH CHECK (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)',
            r.table_name
        );
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 5. Privileges: anon has nothing. Authenticated cannot mutate the WORM ledger.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    r record;
    denylist text[] := ARRAY['spatial_ref_sys'];
BEGIN
    FOR r IN
        SELECT n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('public', 'archive')
          AND c.relkind = 'r'
          AND NOT (n.nspname = 'public' AND c.relname = ANY (denylist))
    LOOP
        EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC', r.schema_name, r.table_name);
        EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM anon', r.schema_name, r.table_name);
        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I.%I TO authenticated',
            r.schema_name,
            r.table_name
        );
        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I.%I TO service_role',
            r.schema_name,
            r.table_name
        );
    END LOOP;
END $$;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.audit_worm_ledger FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.audit_worm_ledger FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.audit_worm_ledger FROM service_role;
GRANT SELECT ON TABLE public.audit_worm_ledger TO authenticated;
GRANT INSERT, SELECT ON TABLE public.audit_worm_ledger TO service_role;

-- -----------------------------------------------------------------------------
-- 6. Verify: fail the transaction if any Orbit table is still RLS-open
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    open_tables text;
    denylist text[] := ARRAY['spatial_ref_sys'];
BEGIN
    SELECT string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY n.nspname, c.relname)
    INTO open_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'archive')
      AND c.relkind = 'r'
      AND NOT (n.nspname = 'public' AND c.relname = ANY (denylist))
      AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity);

    IF open_tables IS NOT NULL THEN
        RAISE EXCEPTION 'DUVAL_WALL: RLS not forced on: %', open_tables;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trig_worm_deny_update_delete'
    ) THEN
        RAISE EXCEPTION 'DUVAL_WALL: WORM deny trigger missing on audit_worm_ledger';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trig_worm_log_trip_manifest'
    ) THEN
        RAISE EXCEPTION 'DUVAL_WALL: trip_manifest WORM log trigger missing';
    END IF;
END $$;

COMMIT;
