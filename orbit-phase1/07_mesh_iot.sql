-- ORBIT PHASE 1 — 07: Trip mesh & IoT scan events

BEGIN;

CREATE TABLE public.route_waypoints (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    sequence_index INT NOT NULL,
    stop_name TEXT NOT NULL,
    location_point GEOGRAPHY(POINT, 4326) NOT NULL,
    geofence_radius_meters INT NOT NULL DEFAULT 50,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (trip_id, sequence_index)
);

CREATE TABLE public.trip_active_mesh (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE UNIQUE,
    current_waypoint_id UUID REFERENCES public.route_waypoints(id) ON DELETE SET NULL,
    next_waypoint_id UUID REFERENCES public.route_waypoints(id) ON DELETE SET NULL,
    estimated_arrival_at TIMESTAMPTZ,
    last_mesh_update TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.student_scan_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
    bus_id UUID NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    waypoint_id UUID REFERENCES public.route_waypoints(id) ON DELETE SET NULL,
    scan_type TEXT NOT NULL CHECK (
        scan_type IN ('BLE_Passive', 'RFID_Tap', 'NFC_Tap', 'Manual_Pilot', 'Manual_Teacher')
    ),
    event_action TEXT NOT NULL CHECK (
        event_action IN ('Boarded', 'Exited', 'Premature_Exit', 'Transfer', 'Halo_Verified', 'Zone_Detection')
    ),
    ble_zone INT NOT NULL DEFAULT 1 CHECK (ble_zone IN (1, 2)),
    location_at_scan GEOGRAPHY(POINT, 4326) NOT NULL,
    is_tap_recovery BOOLEAN NOT NULL DEFAULT false,
    device_timestamp TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    synced_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMIT;
