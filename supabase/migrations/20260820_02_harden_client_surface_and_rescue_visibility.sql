-- Verified live on Orbit Systems Staging (ydlwukjzqtssbzirnefs).
-- Tightens browser-role privileges and exposes only the rescue reads required by Command/Central.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

REVOKE INSERT, DELETE, UPDATE ON TABLE public.staff_profiles FROM authenticated;
GRANT SELECT ON TABLE public.staff_profiles TO authenticated;
GRANT UPDATE (preferred_language, profile_photo_url, is_on_duty)
  ON TABLE public.staff_profiles TO authenticated;

DROP POLICY IF EXISTS staff_view_self ON public.staff_profiles;
CREATE POLICY staff_view_self
ON public.staff_profiles
FOR SELECT
TO authenticated
USING ((SELECT auth.uid()) = id);

DROP POLICY IF EXISTS staff_update_self ON public.staff_profiles;
CREATE POLICY staff_update_self
ON public.staff_profiles
FOR UPDATE
TO authenticated
USING ((SELECT auth.uid()) = id)
WITH CHECK ((SELECT auth.uid()) = id);

GRANT SELECT ON TABLE public.bus_trip_handshakes, public.rescue_handshakes, public.halo_sessions TO authenticated;

DROP POLICY IF EXISTS command_central_view_bus_trip_handshakes ON public.bus_trip_handshakes;
CREATE POLICY command_central_view_bus_trip_handshakes
ON public.bus_trip_handshakes
FOR SELECT
TO authenticated
USING (
  (SELECT public.get_my_role()) = ANY (ARRAY['Command'::text, 'Central'::text, 'Superintendent'::text])
  AND tenant_id = (SELECT public.jwt_tenant_id())
);

DROP POLICY IF EXISTS command_central_view_rescue_handshakes ON public.rescue_handshakes;
CREATE POLICY command_central_view_rescue_handshakes
ON public.rescue_handshakes
FOR SELECT
TO authenticated
USING (
  (SELECT public.get_my_role()) = ANY (ARRAY['Command'::text, 'Central'::text, 'Superintendent'::text])
  AND tenant_id = (SELECT public.jwt_tenant_id())
);

DROP POLICY IF EXISTS command_central_view_halo_sessions ON public.halo_sessions;
CREATE POLICY command_central_view_halo_sessions
ON public.halo_sessions
FOR SELECT
TO authenticated
USING (
  (SELECT public.get_my_role()) = ANY (ARRAY['Command'::text, 'Central'::text, 'Superintendent'::text])
  AND tenant_id = (SELECT public.jwt_tenant_id())
);

REVOKE EXECUTE ON FUNCTION public.gate_transit_mode_trip() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gate_transit_trip_session() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.process_forensic_audit() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_transit_trip_from_trip() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_trip_lock_from_transit() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.worm_log_trip_manifest() FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.set_updated_at() SET search_path = public;
ALTER FUNCTION public.deny_telemetry_mutation() SET search_path = public;
