-- STAGING ONLY. Not applied.
-- Project: ydlwukjzqtssbzirnefs. Do not run against production.
--
-- 20261022135614 bind_parent_student_authorization_to_auth_uid_20261022
-- is already applied on staging and is not rewritten here.
-- This file adds a tenant match to the two functions whose live bodies
-- were read on 2026-10-23. It does not change EXECUTE grants.

CREATE OR REPLACE FUNCTION public.is_parent_of_student(
  p_student_id uuid,
  p_parent_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $$
  SELECT auth.uid() IS NOT NULL
     AND public.jwt_tenant_id() IS NOT NULL
     AND p_parent_id IS NOT DISTINCT FROM auth.uid()
     AND EXISTS (
       SELECT 1
       FROM public.student_guardians sg
       WHERE sg.student_id = p_student_id
         AND sg.parent_id = auth.uid()
         AND sg.tenant_id IS NOT DISTINCT FROM public.jwt_tenant_id()
     );
$$;

CREATE OR REPLACE FUNCTION public.satellite_record_paper_chaperone_application(
  p_trip_id uuid,
  p_student_id uuid,
  p_parent_id uuid,
  p_application_data jsonb DEFAULT '{}'::jsonb,
  p_document_ref text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_assignment public.field_trip_teacher_assignments%ROWTYPE;
  v_hierarchy text;
  v_app_id uuid;
BEGIN
  IF public.jwt_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'AUTHORITY_ERROR: tenant claim is required'
      USING ERRCODE = '42501';
  END IF;

  SELECT a.*
  INTO v_assignment
  FROM public.field_trip_student_invitations i
  JOIN public.field_trip_teacher_assignments a ON a.id = i.teacher_assignment_id
  WHERE i.trip_id = p_trip_id
    AND i.student_id = p_student_id
    AND i.invitation_status = 'INVITED'
    AND i.tenant_id = public.jwt_tenant_id()
    AND a.tenant_id = public.jwt_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FIELD_TRIP_INVITATION_NOT_FOUND';
  END IF;

  v_hierarchy := public.transit_hierarchy_for(p_trip_id, auth.uid());

  IF auth.uid() <> v_assignment.teacher_id
     AND COALESCE(v_hierarchy, '') NOT IN ('primary_lead', 'co_lead') THEN
    RAISE EXCEPTION 'AUTHORITY_ERROR: assigned Satellite or Lead/Co-Lead required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.student_guardians sg
    WHERE sg.student_id = p_student_id
      AND sg.parent_id = p_parent_id
      AND sg.tenant_id = public.jwt_tenant_id()
  ) THEN
    RAISE EXCEPTION 'PARENT_STUDENT_RELATIONSHIP_NOT_FOUND'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.field_trip_chaperone_applications (
    tenant_id, trip_id, parent_id, student_id, teacher_assignment_id,
    submission_method, application_status, document_ref, application_data,
    submitted_at
  )
  VALUES (
    public.jwt_tenant_id(), p_trip_id, p_parent_id, p_student_id,
    v_assignment.id,
    CASE WHEN p_document_ref IS NULL THEN 'PAPER_MANUAL' ELSE 'PAPER_UPLOAD' END,
    'SUBMITTED', p_document_ref, COALESCE(p_application_data, '{}'::jsonb),
    clock_timestamp()
  )
  ON CONFLICT (trip_id, parent_id) DO UPDATE
  SET student_id = EXCLUDED.student_id,
      teacher_assignment_id = EXCLUDED.teacher_assignment_id,
      submission_method = EXCLUDED.submission_method,
      application_status = 'SUBMITTED',
      document_ref = EXCLUDED.document_ref,
      application_data = EXCLUDED.application_data,
      submitted_at = clock_timestamp(),
      reviewed_by = NULL,
      reviewed_at = NULL,
      updated_at = clock_timestamp()
  RETURNING id INTO v_app_id;

  RETURN v_app_id;
END;
$$;
