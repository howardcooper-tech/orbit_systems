-- Verified live on Orbit Systems Staging (ydlwukjzqtssbzirnefs).
-- RLS-safe compatibility bridge for the current Lovable Command map/grid.

GRANT SELECT ON TABLE public.schools, public.contractors TO authenticated;

DROP POLICY IF EXISTS command_central_view_schools ON public.schools;
CREATE POLICY command_central_view_schools
ON public.schools
FOR SELECT
TO authenticated
USING (
  (SELECT public.get_my_role()) = ANY (ARRAY['Command'::text, 'Central'::text, 'Superintendent'::text, 'Principal'::text])
  AND tenant_id = (SELECT public.jwt_tenant_id())
);

DROP POLICY IF EXISTS command_central_view_contractors ON public.contractors;
CREATE POLICY command_central_view_contractors
ON public.contractors
FOR SELECT
TO authenticated
USING (
  (SELECT public.get_my_role()) = ANY (ARRAY['Command'::text, 'Central'::text, 'Superintendent'::text])
  AND tenant_id = (SELECT public.jwt_tenant_id())
);

CREATE OR REPLACE VIEW public.view_command_live_manifest
WITH (security_invoker = true)
AS
SELECT
  b.id AS bus_id,
  b.bus_number,
  ('Unit ' || b.bus_number) AS label,
  CASE
    WHEN b.status = 'Grounded' OR b.is_grounded THEN 'Emergency'
    WHEN b.motion_status = 'Offline' THEN 'Offline'
    WHEN b.route_status = 'At_Stop' THEN 'At_Stop'
    WHEN b.route_status IN ('En_Route', 'Arriving') THEN 'In_Transit'
    ELSE 'Idle'
  END::text AS route_status,
  (
    SELECT count(*)::int
    FROM public.students s
    WHERE s.current_bus_id = b.id
      AND s.current_status = 'boarded'
  ) AS current_headcount,
  NULL::integer AS eta_minutes,
  COALESCE(
    CASE WHEN b.current_location IS NOT NULL THEN ST_Y(b.current_location::geometry) END,
    CASE WHEN sch.geofence_center IS NOT NULL THEN ST_Y(sch.geofence_center::geometry) END,
    CASE WHEN sch.location_point IS NOT NULL THEN ST_Y(sch.location_point::geometry) END,
    30.3322::double precision
  ) AS latitude,
  COALESCE(
    CASE WHEN b.current_location IS NOT NULL THEN ST_X(b.current_location::geometry) END,
    CASE WHEN sch.geofence_center IS NOT NULL THEN ST_X(sch.geofence_center::geometry) END,
    CASE WHEN sch.location_point IS NOT NULL THEN ST_X(sch.location_point::geometry) END,
    (-81.6557)::double precision
  ) AS longitude,
  0::integer AS heading,
  (b.status = 'Active' AND NOT b.is_grounded) AS is_active,
  b.contractor_id,
  c.company_name AS contractor_name,
  b.school_id,
  sch.school_name
FROM public.buses b
LEFT JOIN public.contractors c ON c.id = b.contractor_id
LEFT JOIN public.schools sch ON sch.id = b.school_id;

REVOKE ALL ON TABLE public.view_command_live_manifest FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.view_command_live_manifest TO authenticated;
