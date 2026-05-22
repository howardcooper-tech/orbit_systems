-- ORBIT PHASE 1 — 02: District infrastructure & identity

BEGIN;

CREATE TABLE public.districts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    state_code TEXT NOT NULL DEFAULT 'FL',
    compliance_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.contractors (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID NOT NULL REFERENCES public.districts(id) ON DELETE CASCADE,
    company_name TEXT NOT NULL,
    carrier_code TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT carrier_code_district_unique UNIQUE (carrier_code, district_id)
);

CREATE TABLE public.schools (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    district_id UUID NOT NULL REFERENCES public.districts(id) ON DELETE CASCADE,
    school_name TEXT NOT NULL,
    school_code TEXT NOT NULL,
    location_point GEOGRAPHY(POINT, 4326),
    geofence_center GEOGRAPHY(POINT, 4326),
    geofence_radius_meters INT NOT NULL DEFAULT 200,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT school_code_district_unique UNIQUE (school_code, district_id)
);

CREATE TABLE public.staff_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    district_id UUID REFERENCES public.districts(id) ON DELETE SET NULL,
    contractor_id UUID REFERENCES public.contractors(id) ON DELETE SET NULL,
    school_id UUID REFERENCES public.schools(id) ON DELETE SET NULL,
    first_name TEXT,
    last_name TEXT,
    full_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN (
        'Superintendent', 'Principal', 'Command', 'Central',
        'Pilot', 'Halo', 'Crew', 'Drone',
        'Teacher', 'Satellite', 'Staff_Teacher', 'Sub_Teacher', 'Lead_Satellite', 'Node',
        'Global_Dispatcher'
    )),
    roles TEXT[] NOT NULL DEFAULT '{}',
    preferred_language TEXT NOT NULL DEFAULT 'en' CHECK (char_length(preferred_language) = 2),
    profile_photo_url TEXT,
    pin_code TEXT,
    hire_date DATE NOT NULL DEFAULT CURRENT_DATE CHECK (hire_date <= CURRENT_DATE),
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_on_duty BOOLEAN NOT NULL DEFAULT false,
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pilot_contractor_bond CHECK (
        (role = 'Pilot' AND contractor_id IS NOT NULL) OR (role <> 'Pilot')
    ),
    CONSTRAINT teacher_school_bond CHECK (
        (role IN ('Teacher', 'Satellite', 'Staff_Teacher', 'Sub_Teacher', 'Lead_Satellite') AND school_id IS NOT NULL)
        OR (role NOT IN ('Teacher', 'Satellite', 'Staff_Teacher', 'Sub_Teacher', 'Lead_Satellite'))
    )
);

CREATE TABLE public.parents (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    is_verified_node BOOLEAN NOT NULL DEFAULT false,
    verification_source TEXT NOT NULL DEFAULT 'District_Direct',
    verified_at TIMESTAMPTZ,
    profile_photo_url TEXT,
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Extended guardian profile (Trust / Node apps); links to auth.users
CREATE TABLE public.guardian_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name TEXT,
    last_name TEXT,
    preferred_language TEXT NOT NULL DEFAULT 'en' CHECK (char_length(preferred_language) = 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMIT;
