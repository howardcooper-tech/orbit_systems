-- ORBIT PHASE 1 — 09: Standing routes, field trips, chaperones

BEGIN;

CREATE TABLE public.routes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    route_name TEXT NOT NULL,
    school_id UUID REFERENCES public.schools(id) ON DELETE SET NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.route_stops (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    route_id UUID NOT NULL REFERENCES public.routes(id) ON DELETE CASCADE,
    stop_name TEXT NOT NULL,
    sequence_order INT NOT NULL,
    geofence_center GEOGRAPHY(POINT, 4326),
    geofence_radius_meters INT NOT NULL DEFAULT 50,
    estimated_arrival_time TIME,
    UNIQUE (route_id, sequence_order)
);

ALTER TABLE public.buses
    ADD CONSTRAINT buses_current_route_id_fkey
        FOREIGN KEY (current_route_id) REFERENCES public.routes(id) ON DELETE SET NULL,
    ADD CONSTRAINT buses_next_route_id_fkey
        FOREIGN KEY (next_route_id) REFERENCES public.routes(id) ON DELETE SET NULL,
    ADD CONSTRAINT buses_last_stop_id_fkey
        FOREIGN KEY (last_stop_id) REFERENCES public.route_stops(id) ON DELETE SET NULL;

CREATE TABLE public.field_trip_venues (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    venue_name TEXT NOT NULL,
    macro_geofence_polygon GEOGRAPHY(POLYGON, 4326),
    parking_area_polygon GEOGRAPHY(POLYGON, 4326),
    emergency_buffer_meters INT NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.trips
    ADD COLUMN venue_id UUID REFERENCES public.field_trip_venues(id) ON DELETE SET NULL;

CREATE TABLE public.trip_chaperone_groups (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
    node_id UUID REFERENCES public.guardian_profiles(id) ON DELETE SET NULL,
    satellite_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    outbound_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    return_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.trip_manifest
    ADD CONSTRAINT trip_manifest_assigned_group_id_fkey
        FOREIGN KEY (assigned_group_id) REFERENCES public.trip_chaperone_groups(id) ON DELETE SET NULL;

CREATE TABLE public.field_trip_checkouts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
    requesting_parent_node_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    approving_satellite_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending', 'Approved', 'Denied')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    resolved_at TIMESTAMPTZ
);

CREATE TABLE public.trip_chaperone_handshakes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    guardian_id UUID NOT NULL REFERENCES public.guardian_profiles(id) ON DELETE CASCADE,
    requested_satellite_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    assigned_satellite_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    handshake_status TEXT NOT NULL DEFAULT 'Pending' CHECK (handshake_status IN ('Pending', 'Approved', 'Rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    resolved_at TIMESTAMPTZ
);

CREATE TABLE public.custody_waiver_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE RESTRICT,
    guardian_id UUID NOT NULL REFERENCES public.guardian_profiles(id) ON DELETE RESTRICT,
    waiver_text TEXT NOT NULL,
    typed_signature TEXT NOT NULL,
    ip_address TEXT,
    device_user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.secondary_authorized_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    phone_number TEXT,
    avatar_url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.student_secondary_authorizations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
    secondary_id UUID NOT NULL REFERENCES public.secondary_authorized_profiles(id) ON DELETE CASCADE,
    authorized_by_parent_id UUID NOT NULL REFERENCES public.guardian_profiles(id) ON DELETE CASCADE,
    relationship_label TEXT NOT NULL,
    morning_track_allowed BOOLEAN NOT NULL DEFAULT true,
    afternoon_track_allowed BOOLEAN NOT NULL DEFAULT true,
    chaperone_approved_status BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (student_id, secondary_id)
);

COMMIT;
