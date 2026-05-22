-- ORBIT PHASE 1 — 08: Emergency flares & dispatch

BEGIN;

CREATE TABLE public.emergency_flares (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID NOT NULL REFERENCES public.districts(id) ON DELETE CASCADE,
    triggered_by_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    bus_id UUID REFERENCES public.buses(id) ON DELETE CASCADE,
    student_id UUID REFERENCES public.students(id) ON DELETE SET NULL,
    flare_type TEXT NOT NULL CHECK (
        flare_type IN (
            'Medical_Student', 'Medical_Staff', 'Crash_Vehicle', 'Hostile_Interference',
            'Mechanical_Critical', 'No_Student_Flag', 'Wrong_Bus_Flag', 'Student_Still_Onboard'
        )
    ),
    severity TEXT NOT NULL DEFAULT 'Level_1' CHECK (
        severity IN ('Level_1', 'Level_2_EMS_Required', 'Level_3_Mass_Casualty', 'High', 'Critical')
    ),
    status TEXT NOT NULL DEFAULT 'Active' CHECK (
        status IN ('Active', 'EMS_En_Route', 'EMS_On_Scene', 'Secured_Closed', 'False_Alarm', 'Pending')
    ),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    initial_location GEOGRAPHY(POINT, 4326) NOT NULL,
    search_timer_started_at TIMESTAMPTZ,
    search_timer_suspended_at TIMESTAMPTZ,
    search_verified_by_satellite_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    search_timer_status TEXT NOT NULL DEFAULT 'Not_Applicable' CHECK (
        search_timer_status IN (
            'Not_Applicable', '15m_Active', '10m_Backup_Active', 'Resolved_Verified', 'Escalated_Failed'
        )
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.incident_dispatch_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    flare_id UUID REFERENCES public.emergency_flares(id) ON DELETE CASCADE,
    command_officer_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
    action_taken TEXT NOT NULL,
    agency_contacted TEXT CHECK (
        agency_contacted IN ('None', '911_Police', '911_Fire_EMS', 'District_Superintendent', 'DOT_Emergency')
    ),
    dispatch_notes TEXT,
    action_timestamp TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMIT;
