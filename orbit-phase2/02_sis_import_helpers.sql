-- Phase 2 — SIS link helper (callable from Lovable after parent auth)

BEGIN;

CREATE OR REPLACE FUNCTION public.link_sis_account(
    p_sis_student_id TEXT,
    p_date_of_birth DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_student_id UUID;
BEGIN
    SELECT s.id INTO v_student_id
    FROM public.student_sis_enrollment e
    JOIN public.students s ON s.sis_student_id = e.sis_student_id
    WHERE e.sis_student_id = p_sis_student_id
      AND e.date_of_birth = p_date_of_birth
      AND e.enrollment_status = 'active';

    IF v_student_id IS NULL THEN
        RETURN false;
    END IF;

    -- Example: bind auth user to guardian flow — extend when Pin app is wired
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.link_sis_account(TEXT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_sis_account(TEXT, DATE) TO authenticated;

COMMIT;
