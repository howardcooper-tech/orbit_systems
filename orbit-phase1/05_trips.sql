-- ORBIT PHASE 1 — 05: Trips, manifest (audit-protected), handshakes, audit log table

BEGIN;

CREATE TABLE public.trips (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID NOT NULL REFERENCES public.districts(id) ON DELETE CASCADE,
    school_id UUID REFERENCES public.schools(id) ON DELETE SET NULL,
    trip_code TEXT NOT NULL,
    trip_type TEXT NOT NULL DEFAULT 'Daily' CHECK (
        trip_type IN ('Daily', 'Field_Trip', 'Special_Needs', 'Athletics')
    ),
    destination TEXT NOT NULL,
    lead_satellite_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'pending_bus_assignment' CHECK (
        status IN ('pending_bus_assignment', 'ready_for_boarding', 'in_progress', 'completed', 'canceled')
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT trip_code_district_unique UNIQUE (trip_code, district_id)
);

CREATE TABLE public.trip_manifest (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE RESTRICT,
    assigned_group_id UUID,
    expected_status TEXT NOT NULL DEFAULT 'EXPECTED' CHECK (
        expected_status IN ('EXPECTED', 'BOARDED', 'ABSENT', 'EXCUSED', 'EXCUSED_CHECKOUT')
    ),
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (trip_id, student_id)
);

CREATE TABLE public.bus_trip_handshakes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    bus_id UUID NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'PENDING_PILOT_ACCEPT' CHECK (
        status IN ('PENDING_PILOT_ACCEPT', 'OPEN_FOR_BOARDING', 'LOCKED_DEPARTED')
    ),
    handshake_timestamp TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (trip_id, bus_id)
);

-- Forensic store (triggers attached in Phase 3)
CREATE TABLE public.audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    action_type TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id UUID,
    old_data JSONB,
    new_data JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.trip_manifest IS 'Audit-protected: trip_id ON DELETE RESTRICT prevents silent manifest loss.';

COMMIT;
