-- ORBIT PHASE 1 — 06: Bay operations & communications

BEGIN;

CREATE TABLE public.bus_inspections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bus_id UUID NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    inspector_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    inspection_type TEXT NOT NULL CHECK (
        inspection_type IN ('Pre_Trip', 'Post_Trip', 'Bay_Review', 'DOT_Audit')
    ),
    inspection_status TEXT NOT NULL CHECK (
        inspection_status IN ('Passed', 'Failed', 'Critical', 'Safety_Pull', 'In_Progress', 'Flagged_Minor', 'Grounded')
    ),
    mileage INT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.maintenance_work_orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bus_id UUID NOT NULL REFERENCES public.buses(id) ON DELETE CASCADE,
    reported_by_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    assigned_crew_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    issue_description TEXT NOT NULL,
    priority TEXT NOT NULL DEFAULT 'Standard' CHECK (
        priority IN ('Low', 'Standard', 'Urgent', 'Critical_Grounded')
    ),
    status TEXT NOT NULL DEFAULT 'Open' CHECK (
        status IN ('Open', 'In_Progress', 'Awaiting_Parts', 'Resolved')
    ),
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.comms_channels (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID NOT NULL REFERENCES public.districts(id) ON DELETE CASCADE,
    trip_id UUID REFERENCES public.trips(id) ON DELETE CASCADE,
    channel_name TEXT NOT NULL,
    channel_type TEXT NOT NULL CHECK (
        channel_type IN ('Trip_Radio', 'Parent_Broadcast', 'Command_Direct', 'Emergency_Flare')
    ),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.comms_messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    channel_id UUID NOT NULL REFERENCES public.comms_channels(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    recipient_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    message_body TEXT NOT NULL,
    priority_flag BOOLEAN NOT NULL DEFAULT false,
    read_by_uuids UUID[] NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMIT;
