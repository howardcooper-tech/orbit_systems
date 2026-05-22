-- ORBIT PHASE 1 — 10: Halo evacuation, alerts, rescue, hardware

BEGIN;

CREATE TABLE public.halo_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    flare_id UUID REFERENCES public.emergency_flares(id) ON DELETE CASCADE,
    bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    pilot_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    rescue_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    hardware_id UUID,
    abandoned_bus_location GEOGRAPHY(POINT, 4326) NOT NULL,
    current_huddle_location GEOGRAPHY(POINT, 4326),
    expected_count INT NOT NULL,
    verified_count INT NOT NULL DEFAULT 0,
    bailout_status TEXT NOT NULL DEFAULT 'Evacuating' CHECK (
        bailout_status IN ('Evacuating', 'Huddled', 'Transferring', 'Rescued_Complete')
    ),
    ems_action_packet JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.halo_manifest_snapshots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    halo_session_id UUID NOT NULL REFERENCES public.halo_sessions(id) ON DELETE CASCADE,
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE RESTRICT,
    verification_type TEXT CHECK (verification_type IN ('Tap', 'PIN', 'Visual_Manual')),
    is_verified BOOLEAN NOT NULL DEFAULT false,
    verified_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'Unverified',
    current_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    trip_id UUID REFERENCES public.trips(id) ON DELETE SET NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at TIMESTAMPTZ
);

CREATE TABLE public.rescue_handshakes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    halo_session_id UUID NOT NULL REFERENCES public.halo_sessions(id) ON DELETE CASCADE,
    source_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    rescue_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'Dispatched' CHECK (
        status IN ('Dispatched', 'In_Proximity', 'Requested', 'Accepted', 'Completed', 'Aborted')
    ),
    handshake_type TEXT CHECK (handshake_type IN ('Bus_to_Bus', 'Halo_to_Bus')),
    initiated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    resolved_at TIMESTAMPTZ
);

CREATE TABLE public.outbound_alerts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    recipient_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    alert_type TEXT NOT NULL CHECK (
        alert_type IN ('Routine_Tap', 'ETA_Warning', 'Emergency_Halo', 'Rescue_Update', 'Drone_Dispatch', 'System_Log')
    ),
    priority TEXT NOT NULL DEFAULT 'Normal' CHECK (priority IN ('Normal', 'High', 'Critical', 'Medium')),
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    transcript TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_audio_override BOOLEAN NOT NULL DEFAULT false,
    is_sent BOOLEAN NOT NULL DEFAULT false,
    sent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.drone_assets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID REFERENCES public.districts(id) ON DELETE SET NULL,
    drone_callsign TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'Docked' CHECK (
        status IN ('Docked', 'Patrol', 'Deploying', 'On_Scene', 'Returning', 'Maintenance')
    ),
    current_location GEOGRAPHY(POINT, 4326),
    battery_level INT NOT NULL DEFAULT 100 CHECK (battery_level BETWEEN 0 AND 100)
);

CREATE TABLE public.trusted_hardware (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    device_fingerprint TEXT NOT NULL UNIQUE,
    assigned_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL,
    device_type TEXT CHECK (device_type IN ('Pilot_Tablet', 'Bay_Tablet', 'Node_Phone', 'Driver_BYOD')),
    last_sync_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true
);

ALTER TABLE public.halo_sessions
    ADD CONSTRAINT halo_sessions_hardware_id_fkey
        FOREIGN KEY (hardware_id) REFERENCES public.trusted_hardware(id) ON DELETE SET NULL;

COMMIT;
