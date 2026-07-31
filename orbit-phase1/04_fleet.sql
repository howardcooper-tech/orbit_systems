-- ORBIT PHASE 1 — 04: Fleet & telemetry (INSERT-only table structure; enforcement in Phase 3)

BEGIN;

CREATE TABLE public.buses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID REFERENCES public.districts(id) ON DELETE SET NULL,
    contractor_id UUID NOT NULL REFERENCES public.contractors(id) ON DELETE CASCADE,
    school_id UUID REFERENCES public.schools(id) ON DELETE SET NULL,
    assigned_pilot_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    bus_number TEXT NOT NULL,
    vin TEXT UNIQUE,
    license_plate TEXT UNIQUE,
    current_location GEOGRAPHY(POINT, 4326),
    status TEXT NOT NULL DEFAULT 'Active' CHECK (
        status IN ('Active', 'Bay_Maintenance', 'Grounded', 'Waiting_On_Parts', 'Decommissioned')
    ),
    motion_status TEXT NOT NULL DEFAULT 'Stopped' CHECK (
        motion_status IN ('Moving', 'Idle', 'Stopped', 'Offline')
    ),
    is_equipped_with_moca BOOLEAN NOT NULL DEFAULT true,
    is_on_campus BOOLEAN NOT NULL DEFAULT true,
    is_remote_locked BOOLEAN NOT NULL DEFAULT false,
    is_grounded BOOLEAN NOT NULL DEFAULT false,
    current_route_id UUID,
    next_route_id UUID,
    last_stop_id UUID,
    route_status TEXT NOT NULL DEFAULT 'Idle' CHECK (
        route_status IN ('Idle', 'En_Route', 'Arriving', 'At_Stop', 'Completed')
    ),
    last_ping TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT bus_number_contractor_unique UNIQUE (bus_number, contractor_id)
);

ALTER TABLE public.students
    ADD COLUMN current_bus_id UUID REFERENCES public.buses(id) ON DELETE SET NULL;

CREATE TABLE public.bus_telemetry_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bus_id UUID NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    location GEOGRAPHY(POINT, 4326) NOT NULL,
    speed_mph INT NOT NULL DEFAULT 0 CHECK (speed_mph >= 0 AND speed_mph < 120),
    device_timestamp TIMESTAMPTZ,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    synced_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.bus_telemetry_logs IS 'Append-only GPS history. Phase 3 adds INSERT-only trigger.';

COMMIT;
