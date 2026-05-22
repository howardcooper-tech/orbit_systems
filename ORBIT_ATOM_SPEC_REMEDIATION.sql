-- ============================================================================
-- ORBIT ATOM: SPEC REMEDIATION MIGRATION
-- Purpose: Bring an existing Orbit Atom database toward ORBIT ATOM ARCHITECTURAL
--          CONSTRAINTS without re-running the full monolith.
-- Run on: Staging Supabase first. Review backfill for sis_student_id.
-- Does NOT: Merge dual trip models or remove legacy tables (manual cleanup).
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- §0  Shared helpers (idempotent)
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.process_forensic_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.audit_logs (user_id, action_type, table_name, record_id, old_data, new_data)
    VALUES (
        auth.uid(),
        TG_OP,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
    );
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT role FROM public.staff_profiles WHERE id = auth.uid() LIMIT 1;
$$;

-- Parent/guardian: no staff_profiles row — returns NULL (policies use auth.uid() for parents).
COMMENT ON FUNCTION public.get_my_role() IS
    'Duval Wall role lookup. Staff only; parents use auth.uid() policies.';

-- --------------------------------------------------------------------------
-- §1  sis_student_id (SIS join key)
-- --------------------------------------------------------------------------

ALTER TABLE public.students
    ADD COLUMN IF NOT EXISTS sis_student_id TEXT,
    ADD COLUMN IF NOT EXISTS date_of_birth DATE;

-- Backfill placeholder for existing rows (replace with real SIS import before NOT NULL)
UPDATE public.students
SET sis_student_id = 'MIGRATE-' || id::text
WHERE sis_student_id IS NULL;

-- Prefer district-scoped uniqueness if school_id can be null during migration
CREATE UNIQUE INDEX IF NOT EXISTS students_sis_student_id_unique
    ON public.students (sis_student_id)
    WHERE sis_student_id IS NOT NULL AND sis_student_id NOT LIKE 'MIGRATE-%';

-- After SIS load, run:
-- ALTER TABLE public.students ALTER COLUMN sis_student_id SET NOT NULL;
-- CREATE UNIQUE INDEX ... (full unique on sis_student_id per district policy)

-- --------------------------------------------------------------------------
-- §2  SIS macro vs BLE micro separation
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.student_sis_enrollment (
    sis_student_id TEXT PRIMARY KEY,
    school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
    enrollment_status TEXT NOT NULL DEFAULT 'active'
        CHECK (enrollment_status IN ('active', 'graduated', 'withdrawn', 'transferred', 'suspended')),
    full_name TEXT NOT NULL,
    date_of_birth DATE,
    medical_alert_flag BOOLEAN DEFAULT false,
    medical_notes TEXT,
    pin_hash TEXT,
    pin_updated_at TIMESTAMPTZ DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Link operational students row to SIS record
ALTER TABLE public.students
    ADD COLUMN IF NOT EXISTS sis_student_id_fk TEXT;

-- Migrate enrollment_status off students if it was added by later patches
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'students' AND column_name = 'enrollment_status'
    ) THEN
        INSERT INTO public.student_sis_enrollment (sis_student_id, school_id, enrollment_status, full_name, date_of_birth, medical_alert_flag, medical_notes, pin_hash, pin_updated_at, archived_at)
        SELECT
            COALESCE(s.sis_student_id, 'MIGRATE-' || s.id::text),
            s.school_id,
            COALESCE(s.enrollment_status, 'active'),
            s.full_name,
            s.date_of_birth,
            s.medical_alert_flag,
            s.medical_notes,
            s.pin_hash,
            s.pin_updated_at,
            s.archived_at
        FROM public.students s
        WHERE s.school_id IS NOT NULL
        ON CONFLICT (sis_student_id) DO UPDATE SET
            enrollment_status = EXCLUDED.enrollment_status,
            updated_at = clock_timestamp();

        UPDATE public.students s
        SET sis_student_id_fk = COALESCE(s.sis_student_id, 'MIGRATE-' || s.id::text)
        WHERE sis_student_id_fk IS NULL;

        ALTER TABLE public.students DROP COLUMN IF EXISTS enrollment_status;
    END IF;
END $$;

-- BLE / operational micro-state only on students (macro lives on student_sis_enrollment)
-- Application code must write enrollment to student_sis_enrollment, presence to students.
COMMENT ON TABLE public.students IS
    'Micro/BLE layer: current_status, missing_status, current_bus_id only. SIS macro: student_sis_enrollment.';

-- Graduation lifecycle on SIS table, not students.current_status
CREATE OR REPLACE FUNCTION public.handle_sis_enrollment_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.enrollment_status IN ('graduated', 'withdrawn')
       AND (OLD.enrollment_status IS DISTINCT FROM NEW.enrollment_status) THEN
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles') THEN
            IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'students' AND column_name = 'user_id'
            ) THEN
                NULL; -- wire Pin/Trust via your authorized_relationships when present
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_sis_enrollment_change ON public.student_sis_enrollment;
CREATE TRIGGER on_sis_enrollment_change
    AFTER UPDATE OF enrollment_status ON public.student_sis_enrollment
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_sis_enrollment_change();

-- --------------------------------------------------------------------------
-- §3  Audit protection: trip_manifest must not CASCADE from trips
-- --------------------------------------------------------------------------

ALTER TABLE public.trip_manifest
    DROP CONSTRAINT IF EXISTS trip_manifest_trip_id_fkey;

ALTER TABLE public.trip_manifest
    ADD CONSTRAINT trip_manifest_trip_id_fkey
    FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE RESTRICT;

-- Optional: preserve manifest when student soft-deleted (RESTRICT instead of CASCADE)
-- ALTER TABLE public.trip_manifest DROP CONSTRAINT IF EXISTS trip_manifest_student_id_fkey;
-- ALTER TABLE public.trip_manifest ADD CONSTRAINT trip_manifest_student_id_fkey
--     FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE RESTRICT;

-- --------------------------------------------------------------------------
-- §4  Duval Wall: reattach staff RLS to get_my_role() (representative set)
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS pilot_view_fleet ON public.buses;
CREATE POLICY pilot_view_fleet ON public.buses
    FOR SELECT
    USING (
        public.get_my_role() = 'Pilot'
        AND (
            contractor_id IN (SELECT contractor_id FROM public.staff_profiles WHERE id = auth.uid())
            OR assigned_pilot_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS pilot_insert_telemetry ON public.bus_telemetry_logs;
CREATE POLICY pilot_insert_telemetry ON public.bus_telemetry_logs
    FOR INSERT
    WITH CHECK (
        public.get_my_role() IN ('Pilot', 'Halo')
        AND bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
    );

DROP POLICY IF EXISTS pilot_view_trips ON public.trips;
CREATE POLICY pilot_view_trips ON public.trips
    FOR SELECT
    USING (
        public.get_my_role() IN ('Pilot', 'Halo')
        AND id IN (
            SELECT trip_id FROM public.bus_trip_handshakes
            WHERE bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
        )
    );

DROP POLICY IF EXISTS "Orbit Map Visibility Policy" ON public.buses;
CREATE POLICY "Orbit Map Visibility Policy" ON public.buses
    FOR SELECT TO authenticated
    USING (
        public.get_my_role() IN ('Command', 'Superintendent', 'Central')
        OR (
            public.get_my_role() = 'Central'
            AND school_id = (SELECT school_id FROM public.staff_profiles WHERE id = auth.uid())
        )
        OR EXISTS (
            SELECT 1
            FROM public.halo_manifest_snapshots hms
            JOIN public.students s ON hms.student_id = s.id
            JOIN public.student_guardians sg ON sg.student_id = s.id
            WHERE hms.current_bus_id = buses.id
              AND hms.status = 'Boarded'
              AND sg.parent_id = auth.uid()
        )
    );

-- NOTE: Re-run similar DROP/CREATE for contractor_fleet_isolation, custody_waiver_logs, etc.
-- Parent tables (parents, student_guardians) may keep auth.uid() — not staff roles.

-- --------------------------------------------------------------------------
-- §5  Forensic audit triggers on all BASE TABLES (documented denylist)
-- --------------------------------------------------------------------------

DO $$
DECLARE
    t TEXT;
    denylist TEXT[] := ARRAY[
        'audit_logs',           -- self-referential
        'bus_telemetry_logs',   -- INSERT-only per SPEC
        'spatial_ref_sys'     -- PostGIS system
        -- Add comms_messages / student_scan_events only if compliance packet approves
    ];
BEGIN
    FOR t IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
    LOOP
        IF t = ANY (denylist) THEN
            CONTINUE;
        END IF;
        EXECUTE format('DROP TRIGGER IF EXISTS trig_audit_%I ON public.%I', t, t);
        EXECUTE format(
            'CREATE TRIGGER trig_audit_%I
             AFTER INSERT OR UPDATE OR DELETE ON public.%I
             FOR EACH ROW EXECUTE FUNCTION public.process_forensic_audit()',
            t, t
        );
    END LOOP;
END $$;

-- SIS enrollment table RLS + audit (new table)
ALTER TABLE public.student_sis_enrollment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_view_sis_enrollment ON public.student_sis_enrollment;
CREATE POLICY staff_view_sis_enrollment ON public.student_sis_enrollment
    FOR SELECT
    USING (
        public.get_my_role() IN ('Command', 'Central', 'Satellite', 'Teacher', 'Superintendent', 'Principal')
        AND school_id IN (
            SELECT id FROM public.schools WHERE district_id = public.get_my_district()
        )
    );

-- --------------------------------------------------------------------------
-- §6  bus_telemetry_logs: INSERT-only (immutable principle)
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.deny_telemetry_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE: bus_telemetry_logs is INSERT-only per Orbit Atom SPEC.';
END;
$$;

DROP TRIGGER IF EXISTS trig_telemetry_insert_only ON public.bus_telemetry_logs;
CREATE TRIGGER trig_telemetry_insert_only
    BEFORE UPDATE OR DELETE ON public.bus_telemetry_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.deny_telemetry_mutation();

-- Replace Chronos DELETE with archive COPY (service role / cron only)
CREATE OR REPLACE FUNCTION public.fn_archive_stale_data()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, archive
AS $$
BEGIN
    -- Telemetry: copy to archive, do NOT delete from hot table (partition/detach separately)
    INSERT INTO archive.bus_telemetry_logs
    SELECT *
    FROM public.bus_telemetry_logs b
    WHERE COALESCE(b.synced_at, b.recorded_at) < (now() - interval '30 days')
      AND NOT EXISTS (
          SELECT 1 FROM archive.bus_telemetry_logs a WHERE a.id = b.id
      );

    -- Audit logs: same pattern
    INSERT INTO archive.audit_logs
    SELECT *
    FROM public.audit_logs a
    WHERE a.created_at < (now() - interval '90 days')
      AND NOT EXISTS (
          SELECT 1 FROM archive.audit_logs x WHERE x.id = a.id
      );

    -- Retention on archive only (does not violate hot-table INSERT-only)
    DELETE FROM archive.bus_telemetry_logs
    WHERE COALESCE(synced_at, recorded_at) < (now() - interval '3 years');

    DELETE FROM archive.audit_logs
    WHERE created_at < (now() - interval '7 years');

    RAISE NOTICE 'Chronos: archive copy completed; hot bus_telemetry_logs unchanged (INSERT-only).';
END;
$$;

-- Fix mesh/rescue triggers to use correct column names (if triggers exist)
CREATE OR REPLACE FUNCTION public.fn_process_mesh_intelligence()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_trip_id UUID;
    v_current_waypoint_id UUID;
    v_next_waypoint_record RECORD;
BEGIN
    SELECT trip_id INTO v_trip_id
    FROM public.bus_trip_handshakes
    WHERE bus_id = NEW.bus_id AND status = 'LOCKED_DEPARTED'
    LIMIT 1;

    IF v_trip_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT current_waypoint_id INTO v_current_waypoint_id
    FROM public.trip_active_mesh
    WHERE trip_id = v_trip_id;

    SELECT location_point, geofence_radius_meters
    INTO v_next_waypoint_record
    FROM public.route_waypoints
    WHERE id = v_current_waypoint_id;

    IF v_next_waypoint_record.location_point IS NOT NULL
       AND ST_DWithin(NEW.location, v_next_waypoint_record.location_point, v_next_waypoint_record.geofence_radius_meters) THEN
        SELECT id INTO v_current_waypoint_id
        FROM public.route_waypoints
        WHERE trip_id = v_trip_id
          AND sequence_index > (
              SELECT sequence_index FROM public.route_waypoints WHERE id = v_current_waypoint_id
          )
        ORDER BY sequence_index ASC
        LIMIT 1;

        UPDATE public.trip_active_mesh
        SET current_waypoint_id = v_current_waypoint_id,
            estimated_arrival_at = clock_timestamp() + interval '10 minutes',
            last_mesh_update = clock_timestamp()
        WHERE trip_id = v_trip_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_monitor_rescue_proximity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_handshake_record RECORD;
    v_target_location GEOGRAPHY;
BEGIN
    SELECT * INTO v_handshake_record
    FROM public.rescue_handshakes
    WHERE rescue_bus_id = NEW.bus_id AND status = 'Dispatched'
    LIMIT 1;

    IF v_handshake_record.id IS NULL THEN
        RETURN NEW;
    END IF;

    IF v_handshake_record.handshake_type = 'Bus_to_Bus' THEN
        SELECT location INTO v_target_location
        FROM public.bus_telemetry_logs
        WHERE bus_id = v_handshake_record.source_bus_id
        ORDER BY recorded_at DESC
        LIMIT 1;
    ELSE
        SELECT current_huddle_location INTO v_target_location
        FROM public.halo_sessions
        WHERE id = v_handshake_record.halo_session_id;
    END IF;

    IF v_target_location IS NOT NULL AND ST_DWithin(NEW.location, v_target_location, 50) THEN
        UPDATE public.rescue_handshakes
        SET status = 'In_Proximity'
        WHERE id = v_handshake_record.id;
    END IF;

    RETURN NEW;
END;
$$;

COMMIT;

-- ============================================================================
-- POST-RUN CHECKLIST (manual)
-- ============================================================================
-- 1. Replace MIGRATE-* sis_student_id values with real SIS feed; SET NOT NULL.
-- 2. Drop students.enrollment_status column after app code uses student_sis_enrollment.
-- 3. Complete RLS rewrite for remaining policies (grep staff_profiles in policies).
-- 4. Align lockbox trigger status to lowercase completed/canceled OR normalize enum.
-- 5. Remove duplicate blocks from Orbit Atom Script.txt; split into supabase/migrations/.
-- 6. Decide: retire profiles + fleet_vehicles or map into staff_profiles / buses.
