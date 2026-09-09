-- Orbit Bay session hardening
-- Corrects self-service override detection and keeps trusted tablet assignments
-- aligned with dynamic work-session replacement.

CREATE OR REPLACE FUNCTION public.bay_down_vehicle(
  p_hub_session_id uuid,
  p_bus_id uuid,
  p_reason text,
  p_requesting_technician_id uuid DEFAULT NULL,
  p_supervisor_override_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_session public.bay_hub_sessions%ROWTYPE;
  v_bus public.buses%ROWTYPE;
  v_requested_by uuid := COALESCE(p_requesting_technician_id, auth.uid());
  v_is_override boolean := v_requested_by IS DISTINCT FROM auth.uid()
    OR NULLIF(btrim(p_supervisor_override_reason), '') IS NOT NULL;
  v_auth_time timestamptz;
  v_event_id uuid;
BEGIN
  SELECT * INTO v_session FROM public.bay_hub_sessions
  WHERE id = p_hub_session_id FOR UPDATE;
  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM v_tenant
     OR v_session.operator_id IS DISTINCT FROM auth.uid()
     OR v_session.session_state <> 'ACTIVE'
     OR v_session.lease_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'BAY_ACTIVE_HUB_SESSION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT private.bay_user_has_hub_authorization(
    auth.uid(), v_tenant, 'CHANGE_SERVICE_STATUS'
  ) THEN
    RAISE EXCEPTION 'BAY_SERVICE_STATUS_AUTHORIZATION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF v_is_override AND NOT private.bay_user_has_hub_authorization(
    auth.uid(), v_tenant, 'SUPERVISOR_OVERRIDE'
  ) THEN
    RAISE EXCEPTION 'BAY_SUPERVISOR_OVERRIDE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF v_is_override AND NULLIF(btrim(p_supervisor_override_reason), '') IS NULL THEN
    RAISE EXCEPTION 'BAY_SUPERVISOR_OVERRIDE_REASON_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF NOT private.bay_user_is_manager(v_requested_by, v_tenant) THEN
    RAISE EXCEPTION 'BAY_REQUESTING_TECHNICIAN_INVALID' USING ERRCODE = '42501';
  END IF;
  v_auth_time := private.bay_fresh_credential_time(300);

  SELECT * INTO v_bus FROM public.buses
  WHERE id = p_bus_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_BUS_NOT_FOUND'; END IF;
  IF v_bus.is_grounded OR v_bus.status = 'Grounded' THEN
    RAISE EXCEPTION 'BAY_BUS_ALREADY_DOWNED' USING ERRCODE = '55000';
  END IF;

  UPDATE public.buses
  SET status = 'Grounded', is_grounded = true, updated_at = clock_timestamp()
  WHERE id = v_bus.id;

  INSERT INTO public.bay_vehicle_service_events(
    tenant_id, bus_id, event_type, reason, requested_by, authorized_by,
    supervisor_override, override_reason, hub_id, hub_session_id,
    credential_verified_at, auth_session_id, prior_vehicle_state,
    resulting_vehicle_state
  ) VALUES (
    v_tenant, v_bus.id, 'DOWNED', btrim(p_reason), v_requested_by, auth.uid(),
    v_is_override, CASE WHEN v_is_override THEN btrim(p_supervisor_override_reason) ELSE NULL END,
    v_session.hub_id, v_session.id, v_auth_time, auth.jwt() ->> 'session_id',
    jsonb_build_object('status', v_bus.status, 'is_grounded', v_bus.is_grounded,
      'is_remote_locked', v_bus.is_remote_locked),
    jsonb_build_object('status', 'Grounded', 'is_grounded', true,
      'is_remote_locked', v_bus.is_remote_locked)
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id', v_event_id,
    'bus_id', v_bus.id,
    'status', 'Grounded',
    'is_grounded', true,
    'requested_by', v_requested_by,
    'authorized_by', auth.uid(),
    'supervisor_override', v_is_override,
    'credential_verified_at', v_auth_time
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_return_vehicle_to_service(
  p_hub_session_id uuid,
  p_bus_id uuid,
  p_reason text,
  p_requesting_technician_id uuid DEFAULT NULL,
  p_supervisor_override_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_session public.bay_hub_sessions%ROWTYPE;
  v_bus public.buses%ROWTYPE;
  v_requested_by uuid := COALESCE(p_requesting_technician_id, auth.uid());
  v_blockers jsonb := '[]'::jsonb;
  v_is_override boolean;
  v_auth_time timestamptz;
  v_event_id uuid;
BEGIN
  SELECT * INTO v_session FROM public.bay_hub_sessions
  WHERE id = p_hub_session_id FOR UPDATE;
  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM v_tenant
     OR v_session.operator_id IS DISTINCT FROM auth.uid()
     OR v_session.session_state <> 'ACTIVE'
     OR v_session.lease_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'BAY_ACTIVE_HUB_SESSION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT private.bay_user_has_hub_authorization(
    auth.uid(), v_tenant, 'CHANGE_SERVICE_STATUS'
  ) THEN
    RAISE EXCEPTION 'BAY_SERVICE_STATUS_AUTHORIZATION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT private.bay_user_is_manager(v_requested_by, v_tenant) THEN
    RAISE EXCEPTION 'BAY_REQUESTING_TECHNICIAN_INVALID' USING ERRCODE = '42501';
  END IF;
  v_auth_time := private.bay_fresh_credential_time(300);

  SELECT * INTO v_bus FROM public.buses
  WHERE id = p_bus_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_BUS_NOT_FOUND'; END IF;
  IF NOT v_bus.is_grounded AND v_bus.status <> 'Grounded' THEN
    RAISE EXCEPTION 'BAY_BUS_NOT_DOWNED' USING ERRCODE = '55000';
  END IF;

  WITH latest_inspections AS (
    SELECT DISTINCT ON (bi.inspection_type)
      bi.id, bi.inspection_type, bi.inspection_status, bi.created_at
    FROM public.bus_inspections bi
    WHERE bi.tenant_id = v_tenant AND bi.bus_id = v_bus.id
    ORDER BY bi.inspection_type, bi.created_at DESC
  ), blockers AS (
    SELECT jsonb_build_object(
      'type', 'WORK_ORDER', 'id', wo.id, 'ticket_number', wo.ticket_number,
      'status', wo.status, 'priority', wo.priority
    ) item
    FROM public.maintenance_work_orders wo
    WHERE wo.tenant_id = v_tenant AND wo.bus_id = v_bus.id
      AND wo.priority = 'Critical_Grounded' AND wo.status <> 'Resolved'
    UNION ALL
    SELECT jsonb_build_object(
      'type', 'INSPECTION', 'id', li.id, 'inspection_type', li.inspection_type,
      'status', li.inspection_status
    )
    FROM latest_inspections li
    WHERE li.inspection_status IN ('Failed', 'Critical', 'Safety_Pull', 'Grounded')
  )
  SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO v_blockers FROM blockers;

  v_is_override := jsonb_array_length(v_blockers) > 0
    OR v_requested_by IS DISTINCT FROM auth.uid()
    OR NULLIF(btrim(p_supervisor_override_reason), '') IS NOT NULL;

  IF v_is_override THEN
    IF NULLIF(btrim(p_supervisor_override_reason), '') IS NULL
       OR NOT private.bay_user_has_hub_authorization(
         auth.uid(), v_tenant, 'SUPERVISOR_OVERRIDE'
       ) THEN
      RAISE EXCEPTION 'BAY_SUPERVISOR_OVERRIDE_REQUIRED' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE public.buses
  SET status = 'Active', is_grounded = false, is_remote_locked = false,
      updated_at = clock_timestamp()
  WHERE id = v_bus.id;

  INSERT INTO public.bay_vehicle_service_events(
    tenant_id, bus_id, event_type, reason, requested_by, authorized_by,
    supervisor_override, override_reason, hub_id, hub_session_id,
    credential_verified_at, auth_session_id, prior_vehicle_state,
    resulting_vehicle_state, open_safety_blockers
  ) VALUES (
    v_tenant, v_bus.id, 'RETURNED_TO_SERVICE', btrim(p_reason),
    v_requested_by, auth.uid(), v_is_override,
    CASE WHEN v_is_override THEN btrim(p_supervisor_override_reason) ELSE NULL END,
    v_session.hub_id, v_session.id, v_auth_time, auth.jwt() ->> 'session_id',
    jsonb_build_object('status', v_bus.status, 'is_grounded', v_bus.is_grounded,
      'is_remote_locked', v_bus.is_remote_locked),
    jsonb_build_object('status', 'Active', 'is_grounded', false,
      'is_remote_locked', false),
    v_blockers
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id', v_event_id,
    'bus_id', v_bus.id,
    'status', 'Active',
    'is_grounded', false,
    'requested_by', v_requested_by,
    'authorized_by', auth.uid(),
    'supervisor_override', v_is_override,
    'open_safety_blockers', v_blockers,
    'credential_verified_at', v_auth_time
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_begin_work_session(
  p_station_code text,
  p_tablet_device_fingerprint text,
  p_pairing_method text DEFAULT 'DOCK'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_station public.bay_workstations%ROWTYPE;
  v_tablet public.trusted_hardware%ROWTYPE;
  v_hours smallint;
  v_session public.bay_work_sessions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT private.bay_can_manage_tenant(v_tenant) THEN
    RAISE EXCEPTION 'BAY_MANAGE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_pairing_method NOT IN ('DOCK', 'NEARBY', 'QR_RECOVERY', 'MANUAL_RECOVERY') THEN
    RAISE EXCEPTION 'BAY_INVALID_PAIRING_METHOD' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_station
  FROM public.bay_workstations ws
  WHERE ws.tenant_id = v_tenant
    AND ws.station_code = p_station_code
    AND ws.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_WORKSTATION_NOT_FOUND'; END IF;

  SELECT * INTO v_tablet
  FROM public.trusted_hardware th
  WHERE th.tenant_id = v_tenant
    AND th.device_fingerprint = p_tablet_device_fingerprint
    AND th.device_type = 'Bay_Tablet'
    AND th.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_TABLET_NOT_TRUSTED' USING ERRCODE = '42501'; END IF;

  SELECT COALESCE(s.pairing_lease_hours, 12) INTO v_hours
  FROM public.bay_tenant_settings s
  WHERE s.tenant_id = v_tenant;
  v_hours := COALESCE(v_hours, 12);

  UPDATE public.trusted_hardware
  SET assigned_staff_id = NULL, last_sync_at = clock_timestamp()
  WHERE id IN (
    SELECT s.tablet_hardware_id
    FROM public.bay_work_sessions s
    WHERE s.tenant_id = v_tenant
      AND s.session_state IN ('ACTIVE', 'DISCONNECTED')
      AND (
        s.workstation_id = v_station.id
        OR s.tablet_hardware_id = v_tablet.id
        OR s.technician_id = auth.uid()
      )
  );

  UPDATE public.bay_work_sessions
  SET session_state = 'REPLACED', ended_at = clock_timestamp(),
      end_reason = 'NEW_PAIRING', updated_at = clock_timestamp()
  WHERE tenant_id = v_tenant
    AND session_state IN ('ACTIVE', 'DISCONNECTED')
    AND (
      workstation_id = v_station.id
      OR tablet_hardware_id = v_tablet.id
      OR technician_id = auth.uid()
    );

  INSERT INTO public.bay_work_sessions(
    tenant_id, technician_id, workstation_id, tablet_hardware_id,
    pairing_method, lease_expires_at
  ) VALUES (
    v_tenant, auth.uid(), v_station.id, v_tablet.id,
    p_pairing_method, clock_timestamp() + make_interval(hours => v_hours)
  )
  RETURNING * INTO v_session;

  UPDATE public.trusted_hardware
  SET assigned_staff_id = auth.uid(), last_sync_at = clock_timestamp()
  WHERE id = v_tablet.id;

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'technician_id', v_session.technician_id,
    'workstation_id', v_session.workstation_id,
    'tablet_hardware_id', v_session.tablet_hardware_id,
    'session_state', v_session.session_state,
    'lease_expires_at', v_session.lease_expires_at
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_replace_tablet(
  p_session_id uuid,
  p_new_tablet_device_fingerprint text,
  p_reason text DEFAULT 'TABLET_FAILURE'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_old public.bay_work_sessions%ROWTYPE;
  v_new_tablet public.trusted_hardware%ROWTYPE;
  v_new public.bay_work_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_old FROM public.bay_work_sessions
  WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_old.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_old.technician_id IS DISTINCT FROM auth.uid()
     OR v_old.session_state NOT IN ('ACTIVE', 'DISCONNECTED') THEN
    RAISE EXCEPTION 'BAY_ACTIVE_SESSION_REQUIRED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_new_tablet FROM public.trusted_hardware
  WHERE tenant_id = v_old.tenant_id
    AND device_fingerprint = p_new_tablet_device_fingerprint
    AND device_type = 'Bay_Tablet'
    AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_TABLET_NOT_TRUSTED' USING ERRCODE = '42501'; END IF;

  UPDATE public.bay_work_sessions
  SET session_state = 'REPLACED', ended_at = clock_timestamp(),
      end_reason = LEFT(COALESCE(NULLIF(btrim(p_reason), ''), 'TABLET_FAILURE'), 120),
      updated_at = clock_timestamp()
  WHERE id = v_old.id;

  UPDATE public.trusted_hardware
  SET assigned_staff_id = NULL, last_sync_at = clock_timestamp()
  WHERE id = v_old.tablet_hardware_id AND assigned_staff_id = auth.uid();

  UPDATE public.bay_work_sessions
  SET session_state = 'REPLACED', ended_at = clock_timestamp(),
      end_reason = 'TABLET_REASSIGNED', updated_at = clock_timestamp()
  WHERE id <> v_old.id
    AND tablet_hardware_id = v_new_tablet.id
    AND session_state IN ('ACTIVE', 'DISCONNECTED');

  INSERT INTO public.bay_work_sessions(
    tenant_id, technician_id, workstation_id, tablet_hardware_id,
    previous_session_id, current_work_order_id, pairing_method, lease_expires_at
  ) VALUES (
    v_old.tenant_id, v_old.technician_id, v_old.workstation_id,
    v_new_tablet.id, v_old.id, v_old.current_work_order_id,
    'MANUAL_RECOVERY', clock_timestamp() + (v_old.lease_expires_at - v_old.paired_at)
  ) RETURNING * INTO v_new;

  UPDATE public.trusted_hardware
  SET assigned_staff_id = auth.uid(), last_sync_at = clock_timestamp()
  WHERE id = v_new_tablet.id;

  UPDATE public.maintenance_work_orders
  SET claim_session_id = v_new.id, last_activity_at = clock_timestamp()
  WHERE claimed_by_id = auth.uid() AND claim_session_id = v_old.id;

  RETURN jsonb_build_object(
    'session_id', v_new.id,
    'previous_session_id', v_old.id,
    'current_work_order_id', v_new.current_work_order_id,
    'session_state', v_new.session_state,
    'lease_expires_at', v_new.lease_expires_at
  );
END
$function$;

REVOKE ALL ON FUNCTION public.bay_down_vehicle(uuid, uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_return_vehicle_to_service(uuid, uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_begin_work_session(text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_replace_tablet(uuid, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.bay_down_vehicle(uuid, uuid, text, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_return_vehicle_to_service(uuid, uuid, text, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_begin_work_session(text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_replace_tablet(uuid, text, text)
  TO authenticated;
