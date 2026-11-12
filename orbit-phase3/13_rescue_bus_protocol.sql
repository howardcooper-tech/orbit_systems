-- =============================================================================
-- Orbit Systems — Rescue Bus Protocol (mid-route mechanical breakdown)
-- =============================================================================
-- Apply AFTER 12_zone1_custody_handshake.sql. Does not rewrite Phase 3c policies.
--
-- RLS switch is bus_trip_handshakes.status:
--   OPEN_FOR_BOARDING | LOCKED_DEPARTED  → driver may see/write the trip
--   REVOKED_RESCUE                       → broken driver is cut off immediately
-- Rescue driver is granted a new active handshake on p_rescue_bus_id.
-- Transfer is WORM-logged (per-student trip_manifest UPDATE + summary row).
-- INSERT emergency_flares drives Command Realtime (channel emergency_flares).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Handshake status: revoke without deleting the custody row
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    cname text;
BEGIN
    SELECT con.conname INTO cname
    FROM pg_constraint con
    WHERE con.conrelid = 'public.bus_trip_handshakes'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status%';

    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE public.bus_trip_handshakes DROP CONSTRAINT %I', cname);
    END IF;

    ALTER TABLE public.bus_trip_handshakes
        ADD CONSTRAINT bus_trip_handshakes_status_check
        CHECK (status IN (
            'PENDING_PILOT_ACCEPT',
            'OPEN_FOR_BOARDING',
            'LOCKED_DEPARTED',
            'REVOKED_RESCUE'
        ));
END $$;

ALTER TABLE public.trip_manifest
    ADD COLUMN IF NOT EXISTS assigned_bus_id uuid REFERENCES public.buses(id) ON DELETE SET NULL;

UPDATE public.trip_manifest m
SET assigned_bus_id = h.bus_id
FROM public.bus_trip_handshakes h
WHERE h.trip_id = m.trip_id
  AND m.assigned_bus_id IS NULL
  AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED');

CREATE INDEX IF NOT EXISTS idx_manifest_assigned_bus
    ON public.trip_manifest (assigned_bus_id)
    WHERE assigned_bus_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 1. Restrictive Pilot/Halo wall: active handshake only
--    Command/Central keep district SELECT via existing permissive policies.
-- -----------------------------------------------------------------------------

DROP POLICY IF EXISTS manifest_pilot_active_handshake ON public.trip_manifest;
CREATE POLICY manifest_pilot_active_handshake ON public.trip_manifest
    AS RESTRICTIVE
    FOR SELECT TO authenticated
    USING (
        public.get_my_role() NOT IN ('Pilot', 'Halo')
        OR trip_id IN (
            SELECT h.trip_id
            FROM public.bus_trip_handshakes h
            JOIN public.buses b ON b.id = h.bus_id
            WHERE b.assigned_pilot_id = auth.uid()
              AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
        )
        OR (
            public.get_my_role() = 'Halo'
            AND trip_id IN (
                SELECT h.trip_id
                FROM public.bus_trip_handshakes h
                JOIN public.buses b ON b.id = h.bus_id
                WHERE h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
                  AND b.contractor_id IS NOT DISTINCT FROM public.get_my_contractor()
            )
        )
    );

DROP POLICY IF EXISTS trip_pilot_active_handshake ON public.trips;
CREATE POLICY trip_pilot_active_handshake ON public.trips
    AS RESTRICTIVE
    FOR SELECT TO authenticated
    USING (
        public.get_my_role() NOT IN ('Pilot', 'Halo')
        OR id IN (
            SELECT h.trip_id
            FROM public.bus_trip_handshakes h
            JOIN public.buses b ON b.id = h.bus_id
            WHERE b.assigned_pilot_id = auth.uid()
              AND h.status IN ('PENDING_PILOT_ACCEPT', 'OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
        )
        OR (
            public.get_my_role() = 'Halo'
            AND id IN (
                SELECT h.trip_id
                FROM public.bus_trip_handshakes h
                JOIN public.buses b ON b.id = h.bus_id
                WHERE h.status IN ('PENDING_PILOT_ACCEPT', 'OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
                  AND b.contractor_id IS NOT DISTINCT FROM public.get_my_contractor()
            )
        )
    );

-- -----------------------------------------------------------------------------
-- 2. RPC
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transfer_manifest_to_rescue(
    p_broken_trip_id uuid,
    p_rescue_bus_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_role text;
    v_trip public.trips%ROWTYPE;
    v_broken public.buses%ROWTYPE;
    v_rescue public.buses%ROWTYPE;
    v_hs public.bus_trip_handshakes%ROWTYPE;
    v_grant_status text;
    v_loc geography;
    v_flare_id uuid;
    v_halo_id uuid;
    v_rescue_hs_id uuid;
    v_revoked_hs_id uuid;
    v_count int;
    v_tenant uuid;
    v_existing uuid;
BEGIN
    IF v_actor IS NULL OR p_broken_trip_id IS NULL OR p_rescue_bus_id IS NULL THEN
        RAISE EXCEPTION 'RESCUE_DENIED'
            USING ERRCODE = '42501';
    END IF;

    v_role := public.get_my_role();

    SELECT * INTO v_trip
    FROM public.trips
    WHERE id = p_broken_trip_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RESCUE_DENIED'
            USING ERRCODE = '42501';
    END IF;

    v_tenant := COALESCE(v_trip.tenant_id, v_trip.district_id);

    IF v_tenant IS DISTINCT FROM public.get_my_district()
       AND v_tenant IS DISTINCT FROM public.jwt_tenant_id() THEN
        RAISE EXCEPTION 'RESCUE_DENIED'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_hs
    FROM public.bus_trip_handshakes
    WHERE trip_id = p_broken_trip_id
      AND status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
    ORDER BY handshake_timestamp DESC
    LIMIT 1;

    IF NOT FOUND THEN
        SELECT h.id INTO v_existing
        FROM public.bus_trip_handshakes h
        WHERE h.trip_id = p_broken_trip_id
          AND h.bus_id = p_rescue_bus_id
          AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED');

        IF v_existing IS NOT NULL THEN
            RETURN jsonb_build_object(
                'ok', true,
                'replay', true,
                'trip_id', p_broken_trip_id,
                'rescue_bus_id', p_rescue_bus_id,
                'handshake_id', v_existing
            );
        END IF;

        RAISE EXCEPTION 'RESCUE_DENIED: no active bus handshake on trip'
            USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_broken FROM public.buses WHERE id = v_hs.bus_id;
    SELECT * INTO v_rescue FROM public.buses WHERE id = p_rescue_bus_id;

    IF v_rescue.id IS NULL OR v_broken.id IS NULL THEN
        RAISE EXCEPTION 'RESCUE_DENIED'
            USING ERRCODE = '42501';
    END IF;

    IF v_rescue.id = v_broken.id THEN
        RAISE EXCEPTION 'RESCUE_DENIED: rescue bus must differ from broken bus'
            USING ERRCODE = 'P0001';
    END IF;

    IF v_role NOT IN ('Command', 'Central', 'Superintendent')
       AND v_broken.assigned_pilot_id IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'RESCUE_DENIED'
            USING ERRCODE = '42501';
    END IF;

    IF v_trip.status NOT IN ('ready_for_boarding', 'in_progress') THEN
        RAISE EXCEPTION 'RESCUE_DENIED: trip is not live'
            USING ERRCODE = 'P0001';
    END IF;

    IF v_rescue.district_id IS DISTINCT FROM v_trip.district_id THEN
        RAISE EXCEPTION 'RESCUE_DENIED: rescue bus is out of tenant'
            USING ERRCODE = '42501';
    END IF;

    IF v_rescue.assigned_pilot_id IS NULL
       OR v_rescue.status NOT IN ('Active')
       OR v_rescue.is_grounded THEN
        RAISE EXCEPTION 'RESCUE_DENIED: rescue bus is not dispatchable'
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.bus_trip_handshakes h
        WHERE h.bus_id = p_rescue_bus_id
          AND h.trip_id IS DISTINCT FROM p_broken_trip_id
          AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
    ) THEN
        RAISE EXCEPTION 'RESCUE_DENIED: rescue bus is already on another live trip'
            USING ERRCODE = 'P0001';
    END IF;

    v_grant_status := CASE
        WHEN v_hs.status = 'OPEN_FOR_BOARDING' THEN 'OPEN_FOR_BOARDING'
        ELSE 'LOCKED_DEPARTED'
    END;

    v_loc := COALESCE(
        v_broken.current_location,
        (SELECT sch.geofence_center FROM public.schools sch WHERE sch.id = v_trip.school_id),
        (SELECT sch.location_point FROM public.schools sch WHERE sch.id = v_trip.school_id),
        (SELECT w.location_point
         FROM public.route_waypoints w
         WHERE w.trip_id = p_broken_trip_id
         ORDER BY w.sequence_index
         LIMIT 1)
    );

    IF v_loc IS NULL THEN
        RAISE EXCEPTION 'RESCUE_DENIED: broken bus location required'
            USING ERRCODE = 'P0001';
    END IF;

    -- Revoke broken driver first (RLS cuts over immediately).
    UPDATE public.bus_trip_handshakes
    SET status = 'REVOKED_RESCUE',
        updated_at = clock_timestamp()
    WHERE id = v_hs.id
    RETURNING id INTO v_revoked_hs_id;

    INSERT INTO public.bus_trip_handshakes (
        tenant_id, trip_id, bus_id, status, handshake_timestamp
    )
    VALUES (
        v_tenant, p_broken_trip_id, p_rescue_bus_id, v_grant_status, clock_timestamp()
    )
    ON CONFLICT (trip_id, bus_id) DO UPDATE
    SET status = EXCLUDED.status,
        handshake_timestamp = EXCLUDED.handshake_timestamp,
        tenant_id = COALESCE(public.bus_trip_handshakes.tenant_id, EXCLUDED.tenant_id),
        updated_at = clock_timestamp()
    RETURNING id INTO v_rescue_hs_id;

    UPDATE public.buses
    SET status = 'Grounded',
        is_grounded = true,
        is_remote_locked = true,
        motion_status = 'Stopped',
        route_status = 'Idle',
        updated_at = clock_timestamp()
    WHERE id = v_broken.id;

    UPDATE public.students
    SET current_bus_id = p_rescue_bus_id,
        updated_at = clock_timestamp()
    WHERE current_bus_id = v_broken.id
      AND id IN (
          SELECT m.student_id FROM public.trip_manifest m WHERE m.trip_id = p_broken_trip_id
      );

    -- Per-student WORM copies via trig_worm_log_trip_manifest.
    UPDATE public.trip_manifest
    SET assigned_bus_id = p_rescue_bus_id,
        updated_at = clock_timestamp()
    WHERE trip_id = p_broken_trip_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO public.emergency_flares (
        tenant_id,
        district_id,
        triggered_by_id,
        bus_id,
        flare_type,
        severity,
        status,
        initial_location,
        metadata
    )
    VALUES (
        v_tenant,
        v_trip.district_id,
        v_actor,
        v_broken.id,
        'Mechanical_Critical',
        'High',
        'Active',
        v_loc,
        jsonb_build_object(
            'protocol', 'rescue_bus',
            'event', 'manifest_transferred',
            'trip_id', p_broken_trip_id,
            'broken_bus_id', v_broken.id,
            'broken_pilot_id', v_broken.assigned_pilot_id,
            'rescue_bus_id', p_rescue_bus_id,
            'rescue_pilot_id', v_rescue.assigned_pilot_id,
            'revoked_handshake_id', v_revoked_hs_id,
            'rescue_handshake_id', v_rescue_hs_id,
            'students_transferred', v_count,
            'channel', 'emergency_flares'
        )
    )
    RETURNING id INTO v_flare_id;

    INSERT INTO public.halo_sessions (
        tenant_id,
        flare_id,
        bus_id,
        pilot_id,
        rescue_bus_id,
        abandoned_bus_location,
        expected_count,
        bailout_status
    )
    VALUES (
        v_tenant,
        v_flare_id,
        v_broken.id,
        v_broken.assigned_pilot_id,
        p_rescue_bus_id,
        v_loc,
        v_count,
        'Transferring'
    )
    RETURNING id INTO v_halo_id;

    INSERT INTO public.rescue_handshakes (
        tenant_id,
        halo_session_id,
        source_bus_id,
        rescue_bus_id,
        status,
        handshake_type,
        initiated_at,
        resolved_at
    )
    VALUES (
        v_tenant,
        v_halo_id,
        v_broken.id,
        p_rescue_bus_id,
        'Accepted',
        'Bus_to_Bus',
        clock_timestamp(),
        clock_timestamp()
    );

    -- Explicit transfer record (in addition to per-student manifest WORM rows).
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
        v_actor,
        'UPDATE',
        'trip_manifest',
        p_broken_trip_id,
        jsonb_build_object(
            'protocol', 'rescue_bus',
            'trip_id', p_broken_trip_id,
            'bus_id', v_broken.id,
            'pilot_id', v_broken.assigned_pilot_id,
            'handshake_id', v_revoked_hs_id,
            'handshake_status', 'REVOKED_RESCUE'
        ),
        jsonb_build_object(
            'protocol', 'rescue_bus',
            'trip_id', p_broken_trip_id,
            'bus_id', p_rescue_bus_id,
            'pilot_id', v_rescue.assigned_pilot_id,
            'handshake_id', v_rescue_hs_id,
            'handshake_status', v_grant_status,
            'flare_id', v_flare_id,
            'halo_session_id', v_halo_id,
            'students_transferred', v_count
        ),
        public.jwt_tenant_id()
    );

    RETURN jsonb_build_object(
        'ok', true,
        'replay', false,
        'trip_id', p_broken_trip_id,
        'broken_bus_id', v_broken.id,
        'rescue_bus_id', p_rescue_bus_id,
        'rescue_pilot_id', v_rescue.assigned_pilot_id,
        'revoked_handshake_id', v_revoked_hs_id,
        'rescue_handshake_id', v_rescue_hs_id,
        'flare_id', v_flare_id,
        'halo_session_id', v_halo_id,
        'students_transferred', v_count,
        'channel', 'emergency_flares'
    );
END;
$$;

COMMENT ON FUNCTION public.transfer_manifest_to_rescue(uuid, uuid) IS
    'Rescue Bus Protocol. Revokes broken-bus handshake (Pilot RLS), grants rescue-bus handshake, WORM-logs the transfer, inserts emergency_flares for Command Realtime.';

REVOKE ALL ON FUNCTION public.transfer_manifest_to_rescue(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transfer_manifest_to_rescue(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.transfer_manifest_to_rescue(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_manifest_to_rescue(uuid, uuid) TO service_role;

COMMIT;
