-- Orbit Bay RLS helper execution grants
-- RLS and Storage policy expressions execute in the caller's authorization
-- context. These four SECURITY DEFINER functions return booleans only; the
-- private schema remains outside the API surface and mutation helpers stay
-- revoked.

GRANT EXECUTE ON FUNCTION private.bay_pilot_can_contribute_inspection(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_contribute_checkpoint(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_view_tenant(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_manage_tenant(uuid)
  TO authenticated;
