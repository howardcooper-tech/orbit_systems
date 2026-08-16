-- =============================================================================
-- Orbit Systems — student_scan_events: idempotent table + manifest-scoped RLS
-- =============================================================================
-- Apply AFTER Phase 3c (Duval Wall). Does not rewrite 3c tenant isolation.
-- Replaces the Phase 3 permissive INSERT policy (pilot_manage_scans).
--
-- Drivers (Pilot / Halo) may INSERT/SELECT only when:
--   1. student_id is on trip_manifest for trip_id
--   2. bus_id is handshake'd onto that trip
--   3. buses.assigned_pilot_id = auth.uid()  (Halo: same contractor on that bus)
-- Command / Central / Superintendent may SELECT district trips (read-only).
-- Append-only: UPDATE / DELETE / TRUNCATE raise.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Table (no-op if Phase 1 already created it)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.student_scan_events (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
    bus_id uuid NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    waypoint_id uuid REFERENCES public.route_waypoints(id) ON DELETE SET NULL,
    scan_type text NOT NULL CHECK (
        scan_type IN ('BLE_Passive', 'RFID_Tap', 'NFC_Tap', 'Manual_Pilot', 'Manual_Teacher')
    ),
    event_action text NOT NULL CHECK (
        event_action IN ('Boarded', 'Exited', 'Premature_Exit', 'Transfer', 'Halo_Verified', 'Zone_Detection')
    ),
    ble_zone int NOT NULL DEFAULT 1 CHECK (ble_zone IN (1, 2)),
    location_at_scan geography(POINT, 4326) NOT NULL,
    is_tap_recovery boolean NOT NULL DEFAULT false,
    device_timestamp timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    synced_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.student_scan_events
    ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES public.districts(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_scan_student_created
    ON public.student_scan_events (student_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_scan_bus_created
    ON public.student_scan_events (bus_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_scan_trip_student
    ON public.student_scan_events (trip_id, student_id, created_at DESC);
CREATE INDEX IF NOT EXISTS student_scan_events_tenant_id_idx
    ON public.student_scan_events (tenant_id);

COMMENT ON TABLE public.student_scan_events IS
    'Append-only boarding/offboard events. Pilot tablet writes via offline outbox. RLS: assigned manifest only.';

-- -----------------------------------------------------------------------------
-- 1. Append-only gate
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.deny_scan_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE: student_scan_events allows INSERT only.'
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

DROP TRIGGER IF EXISTS trig_scan_events_insert_only ON public.student_scan_events;
CREATE TRIGGER trig_scan_events_insert_only
    BEFORE UPDATE OR DELETE ON public.student_scan_events
    FOR EACH ROW
    EXECUTE FUNCTION public.deny_scan_event_mutation();

DROP TRIGGER IF EXISTS trig_scan_events_deny_truncate ON public.student_scan_events;
CREATE TRIGGER trig_scan_events_deny_truncate
    BEFORE TRUNCATE ON public.student_scan_events
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.deny_scan_event_mutation();

REVOKE ALL ON FUNCTION public.deny_scan_event_mutation() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 2. Assigned-manifest predicate (SECURITY DEFINER: avoid RLS recursion)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pilot_assigned_manifest_scan(
    p_student_id uuid,
    p_bus_id uuid,
    p_trip_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        p_student_id IS NOT NULL
        AND p_bus_id IS NOT NULL
        AND p_trip_id IS NOT NULL
        AND public.get_my_role() IN ('Pilot', 'Halo')
        AND EXISTS (
            SELECT 1
            FROM public.trip_manifest m
            WHERE m.trip_id = p_trip_id
              AND m.student_id = p_student_id
        )
        AND EXISTS (
            SELECT 1
            FROM public.bus_trip_handshakes h
            JOIN public.buses b ON b.id = h.bus_id
            WHERE h.trip_id = p_trip_id
              AND h.bus_id = p_bus_id
              AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
              AND (
                  b.assigned_pilot_id = auth.uid()
                  OR (
                      public.get_my_role() = 'Halo'
                      AND b.contractor_id IS NOT DISTINCT FROM public.get_my_contractor()
                  )
              )
        )
$$;

COMMENT ON FUNCTION public.pilot_assigned_manifest_scan(uuid, uuid, uuid) IS
    'True when the current Pilot/Halo may write a scan: student on trip_manifest and bus handshake-assigned to this driver.';

REVOKE ALL ON FUNCTION public.pilot_assigned_manifest_scan(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pilot_assigned_manifest_scan(uuid, uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.pilot_assigned_manifest_scan(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pilot_assigned_manifest_scan(uuid, uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. RLS: keep Duval FORCE + tenant wall; replace loose INSERT
-- -----------------------------------------------------------------------------

ALTER TABLE public.student_scan_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.student_scan_events FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pilot_manage_scans ON public.student_scan_events;
DROP POLICY IF EXISTS scan_events_pilot_insert ON public.student_scan_events;
DROP POLICY IF EXISTS scan_events_pilot_select ON public.student_scan_events;
DROP POLICY IF EXISTS scan_events_command_select ON public.student_scan_events;

CREATE POLICY scan_events_pilot_insert ON public.student_scan_events
    FOR INSERT TO authenticated
    WITH CHECK (
        public.pilot_assigned_manifest_scan(student_id, bus_id, trip_id)
    );

CREATE POLICY scan_events_pilot_select ON public.student_scan_events
    FOR SELECT TO authenticated
    USING (
        public.pilot_assigned_manifest_scan(student_id, bus_id, trip_id)
    );

CREATE POLICY scan_events_command_select ON public.student_scan_events
    FOR SELECT TO authenticated
    USING (
        public.get_my_role() IN ('Command', 'Central', 'Superintendent')
        AND trip_id IN (
            SELECT t.id FROM public.trips t
            WHERE t.district_id = public.get_my_district()
        )
    );

-- 3c restrictive policies (duval_deny_all / duval_tenant_isolation) remain.

REVOKE ALL ON TABLE public.student_scan_events FROM PUBLIC;
REVOKE ALL ON TABLE public.student_scan_events FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.student_scan_events FROM authenticated;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.student_scan_events FROM service_role;
GRANT SELECT, INSERT ON TABLE public.student_scan_events TO authenticated;
GRANT SELECT, INSERT ON TABLE public.student_scan_events TO service_role;

COMMIT;
