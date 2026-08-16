-- =============================================================================
-- Orbit Systems — Zone 1 Custody Handshake
-- =============================================================================
-- Apply AFTER 11_student_scan_events.sql.
-- Parent Point "I'm here" is authorized only via this RPC (authenticated JWT).
-- Edge Function parent_zone1_im_here calls this, then Realtime-notifies the Pilot.
-- =============================================================================

BEGIN;

ALTER TABLE public.student_scan_events
    ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES public.parents(id) ON DELETE SET NULL;

ALTER TABLE public.student_scan_events
    ADD COLUMN IF NOT EXISTS headshot_url text;

COMMENT ON COLUMN public.student_scan_events.parent_id IS
    'Point parent who initiated a Zone 1 custody ping. NULL for Pilot/BLE scans.';
COMMENT ON COLUMN public.student_scan_events.headshot_url IS
    'Snapshot of parents.profile_photo_url at ping time for Pilot visual confirm.';

DO $$
DECLARE
    cname text;
BEGIN
    SELECT con.conname INTO cname
    FROM pg_constraint con
    WHERE con.conrelid = 'public.student_scan_events'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%scan_type%';

    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE public.student_scan_events DROP CONSTRAINT %I', cname);
    END IF;

    ALTER TABLE public.student_scan_events
        ADD CONSTRAINT student_scan_events_scan_type_check
        CHECK (scan_type IN (
            'BLE_Passive', 'RFID_Tap', 'NFC_Tap', 'Manual_Pilot', 'Manual_Teacher', 'Parent_Point'
        ));
END $$;

CREATE INDEX IF NOT EXISTS idx_scan_zone1_parent_trip
    ON public.student_scan_events (trip_id, parent_id, created_at DESC)
    WHERE scan_type = 'Parent_Point';

-- -----------------------------------------------------------------------------
-- RPC: fail-closed Zone 1 authorization + append-only scan insert
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.parent_zone1_im_here(
    p_student_id uuid,
    p_trip_id uuid,
    p_latitude double precision,
    p_longitude double precision,
    p_stop_id uuid DEFAULT NULL,
    p_waypoint_id uuid DEFAULT NULL,
    p_device_timestamp timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_parent uuid := auth.uid();
    v_now timestamptz := clock_timestamp();
    v_ts timestamptz;
    v_tenant uuid;
    v_headshot text;
    v_display text;
    v_bus uuid;
    v_pilot uuid;
    v_waypoint uuid;
    v_center geography;
    v_radius int;
    v_scan uuid;
    v_loc geography;
    v_recent uuid;
BEGIN
    IF v_parent IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    IF p_student_id IS NULL OR p_trip_id IS NULL
       OR p_latitude IS NULL OR p_longitude IS NULL
       OR p_latitude < -90 OR p_latitude > 90
       OR p_longitude < -180 OR p_longitude > 180 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    v_ts := COALESCE(p_device_timestamp, v_now);
    v_loc := ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography;

    -- 1. Guardian link
    IF NOT EXISTS (
        SELECT 1
        FROM public.student_guardians sg
        JOIN public.parents p ON p.id = sg.parent_id
        JOIN public.students s ON s.id = sg.student_id
        WHERE sg.parent_id = v_parent
          AND sg.student_id = p_student_id
          AND p.archived_at IS NULL
          AND s.archived_at IS NULL
    ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    -- 2. Manifest authorization for this trip
    IF NOT EXISTS (
        SELECT 1
        FROM public.trip_manifest m
        JOIN public.trips t ON t.id = m.trip_id
        WHERE m.trip_id = p_trip_id
          AND m.student_id = p_student_id
          AND m.expected_status IN ('EXPECTED', 'BOARDED', 'EXCUSED_CHECKOUT')
          AND t.status IN ('ready_for_boarding', 'in_progress')
    ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    -- 3. Stop / waypoint geofence (Zone 1)
    IF p_waypoint_id IS NOT NULL THEN
        SELECT w.id, w.location_point, w.geofence_radius_meters
        INTO v_waypoint, v_center, v_radius
        FROM public.route_waypoints w
        WHERE w.id = p_waypoint_id
          AND w.trip_id = p_trip_id
          AND w.is_active;

        IF v_center IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
        END IF;
    ELSIF p_stop_id IS NOT NULL THEN
        SELECT rs.geofence_center, rs.geofence_radius_meters
        INTO v_center, v_radius
        FROM public.route_stops rs
        JOIN public.routes r ON r.id = rs.route_id
        JOIN public.students s ON s.id = p_student_id
        WHERE rs.id = p_stop_id
          AND rs.geofence_center IS NOT NULL
          AND (
              r.school_id = s.school_id
              OR EXISTS (
                  SELECT 1
                  FROM public.bus_trip_handshakes h
                  JOIN public.buses b ON b.id = h.bus_id
                  WHERE h.trip_id = p_trip_id
                    AND b.current_route_id = r.id
              )
          );

        IF v_center IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
        END IF;
    ELSE
        SELECT s.assigned_stop_point, 50
        INTO v_center, v_radius
        FROM public.students s
        WHERE s.id = p_student_id
          AND s.assigned_stop_point IS NOT NULL;
    END IF;

    IF v_center IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    v_radius := GREATEST(15, LEAST(COALESCE(v_radius, 50), 150));

    IF NOT ST_DWithin(v_loc, v_center, v_radius) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    -- 4. Assigned bus + Pilot tablet
    SELECT h.bus_id, b.assigned_pilot_id, COALESCE(t.tenant_id, t.district_id)
    INTO v_bus, v_pilot, v_tenant
    FROM public.bus_trip_handshakes h
    JOIN public.buses b ON b.id = h.bus_id
    JOIN public.trips t ON t.id = h.trip_id
    WHERE h.trip_id = p_trip_id
      AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
      AND (
          b.id = (SELECT s.current_bus_id FROM public.students s WHERE s.id = p_student_id)
          OR NOT EXISTS (
              SELECT 1 FROM public.students s
              WHERE s.id = p_student_id AND s.current_bus_id IS NOT NULL
          )
      )
    ORDER BY h.handshake_timestamp DESC
    LIMIT 1;

    IF v_bus IS NULL THEN
        SELECT h.bus_id, b.assigned_pilot_id, COALESCE(t.tenant_id, t.district_id)
        INTO v_bus, v_pilot, v_tenant
        FROM public.bus_trip_handshakes h
        JOIN public.buses b ON b.id = h.bus_id
        JOIN public.trips t ON t.id = h.trip_id
        WHERE h.trip_id = p_trip_id
          AND h.status IN ('OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
        ORDER BY h.handshake_timestamp DESC
        LIMIT 1;
    END IF;

    IF v_bus IS NULL OR v_pilot IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ZONE1_DENIED');
    END IF;

    SELECT p.profile_photo_url, p.full_name
    INTO v_headshot, v_display
    FROM public.parents p
    WHERE p.id = v_parent;

    -- Idempotent replay window (20s)
    SELECT e.id INTO v_recent
    FROM public.student_scan_events e
    WHERE e.scan_type = 'Parent_Point'
      AND e.parent_id = v_parent
      AND e.student_id = p_student_id
      AND e.trip_id = p_trip_id
      AND e.created_at > v_now - interval '20 seconds'
    ORDER BY e.created_at DESC
    LIMIT 1;

    IF v_recent IS NOT NULL THEN
        RETURN jsonb_build_object(
            'ok', true,
            'replay', true,
            'scan_id', v_recent,
            'trip_id', p_trip_id,
            'bus_id', v_bus,
            'student_id', p_student_id,
            'pilot_id', v_pilot,
            'waypoint_id', v_waypoint,
            'ble_zone', 1,
            'headshot_url', v_headshot,
            'parent_display_name', v_display,
            'channel', 'student_scan_events',
            'topic', format('student_scan_events:bus:%s', v_bus)
        );
    END IF;

    INSERT INTO public.student_scan_events (
        tenant_id,
        student_id,
        bus_id,
        trip_id,
        waypoint_id,
        parent_id,
        headshot_url,
        scan_type,
        event_action,
        ble_zone,
        location_at_scan,
        is_tap_recovery,
        device_timestamp
    )
    VALUES (
        v_tenant,
        p_student_id,
        v_bus,
        p_trip_id,
        v_waypoint,
        v_parent,
        v_headshot,
        'Parent_Point',
        'Zone_Detection',
        1,
        v_loc,
        false,
        v_ts
    )
    RETURNING id INTO v_scan;

    RETURN jsonb_build_object(
        'ok', true,
        'replay', false,
        'scan_id', v_scan,
        'trip_id', p_trip_id,
        'bus_id', v_bus,
        'student_id', p_student_id,
        'pilot_id', v_pilot,
        'waypoint_id', v_waypoint,
        'ble_zone', 1,
        'headshot_url', v_headshot,
        'parent_display_name', v_display,
        'channel', 'student_scan_events',
        'topic', format('student_scan_events:bus:%s', v_bus)
    );
END;
$$;

COMMENT ON FUNCTION public.parent_zone1_im_here(uuid, uuid, double precision, double precision, uuid, uuid, timestamptz) IS
    'Point Zone 1 custody ping. Verifies student_guardians + trip_manifest + stop geofence. Inserts student_scan_events for Pilot Realtime.';

REVOKE ALL ON FUNCTION public.parent_zone1_im_here(uuid, uuid, double precision, double precision, uuid, uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.parent_zone1_im_here(uuid, uuid, double precision, double precision, uuid, uuid, timestamptz) FROM anon;
GRANT EXECUTE ON FUNCTION public.parent_zone1_im_here(uuid, uuid, double precision, double precision, uuid, uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.parent_zone1_im_here(uuid, uuid, double precision, double precision, uuid, uuid, timestamptz) TO service_role;

COMMIT;
