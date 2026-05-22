-- ORBIT PHASE 1 — 03: SIS macro layer + BLE micro layer

BEGIN;

-- MACRO (SIS): enrollment, legal identity, medical flags from district feed
CREATE TABLE public.student_sis_enrollment (
    sis_student_id TEXT PRIMARY KEY,
    school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
    enrollment_status TEXT NOT NULL DEFAULT 'active' CHECK (
        enrollment_status IN ('active', 'graduated', 'withdrawn', 'transferred', 'suspended')
    ),
    full_name TEXT NOT NULL,
    date_of_birth DATE,
    medical_alert_flag BOOLEAN NOT NULL DEFAULT false,
    medical_notes TEXT,
    pin_hash TEXT,
    pin_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- MICRO (BLE / operations): presence on bus, scans, flares — no enrollment_status here
CREATE TABLE public.students (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sis_student_id TEXT NOT NULL UNIQUE REFERENCES public.student_sis_enrollment(sis_student_id) ON DELETE RESTRICT,
    school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
    assigned_stop_point GEOGRAPHY(POINT, 4326),
    current_status TEXT NOT NULL DEFAULT 'off_bus' CHECK (
        current_status IN ('off_bus', 'boarded', 'missing', 'medical_hold')
    ),
    missing_status TEXT NOT NULL DEFAULT 'NONE' CHECK (
        missing_status IN ('NONE', 'PENDING_MANUAL', 'SUSPENDED', 'FLARE_ACTIVE')
    ),
    status_note TEXT,
    last_known_gps GEOGRAPHY(POINT, 4326),
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.student_guardians (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE RESTRICT,
    parent_id UUID NOT NULL REFERENCES public.parents(id) ON DELETE CASCADE,
    relationship TEXT NOT NULL DEFAULT 'Guardian',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (student_id, parent_id)
);

CREATE TABLE public.student_device_authorizations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
    parent_id UUID NOT NULL REFERENCES public.parents(id) ON DELETE CASCADE,
    device_token TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (student_id, parent_id, device_token)
);

COMMENT ON TABLE public.student_sis_enrollment IS 'SIS macro layer: enrollment and district master record.';
COMMENT ON TABLE public.students IS 'BLE/ops micro layer: live bus presence only; join via sis_student_id.';

COMMIT;
