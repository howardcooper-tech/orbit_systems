-- Phase 2 — OPTIONAL dev seed (staging only). Skip for real SIS import.

BEGIN;

INSERT INTO public.districts (id, name, state_code, compliance_id)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'Duval County Public Schools (DEV)',
    'FL',
    'DEV-DUVAL'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.schools (id, district_id, school_name, school_code)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    '11111111-1111-1111-1111-111111111111',
    'Dev Elementary',
    'DEV-001'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.contractors (id, district_id, company_name, carrier_code)
VALUES (
    '33333333-3333-3333-3333-333333333333',
    '11111111-1111-1111-1111-111111111111',
    'Dev Carrier LLC',
    'DEVBUS'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.student_sis_enrollment (sis_student_id, school_id, full_name, date_of_birth, enrollment_status)
VALUES
    ('SIS-10001', '22222222-2222-2222-2222-222222222222', 'Alex Dev Student', '2015-03-15', 'active'),
    ('SIS-10002', '22222222-2222-2222-2222-222222222222', 'Jordan Dev Student', '2014-08-22', 'active')
ON CONFLICT (sis_student_id) DO NOTHING;

INSERT INTO public.students (sis_student_id, school_id, current_status)
VALUES
    ('SIS-10001', '22222222-2222-2222-2222-222222222222', 'off_bus'),
    ('SIS-10002', '22222222-2222-2222-2222-222222222222', 'off_bus')
ON CONFLICT (sis_student_id) DO NOTHING;

INSERT INTO public.buses (id, district_id, contractor_id, bus_number, status)
VALUES (
    '44444444-4444-4444-4444-444444444444',
    '11111111-1111-1111-1111-111111111111',
    '33333333-3333-3333-3333-333333333333',
    'DEV-42',
    'Active'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.trips (id, district_id, trip_code, destination, status)
VALUES (
    '55555555-5555-5555-5555-555555555555',
    '11111111-1111-1111-1111-111111111111',
    'DEV-AM-001',
    'Dev Elementary',
    'ready_for_boarding'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.trip_manifest (trip_id, student_id, expected_status)
SELECT
    '55555555-5555-5555-5555-555555555555',
    s.id,
    'EXPECTED'
FROM public.students s
WHERE s.sis_student_id IN ('SIS-10001', 'SIS-10002')
ON CONFLICT (trip_id, student_id) DO NOTHING;

COMMIT;
