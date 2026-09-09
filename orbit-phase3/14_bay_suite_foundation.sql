-- Orbit Bay Suite foundation
-- Staging target: Orbit Systems Staging (ydlwukjzqtssbzirnefs)
-- Additive operational layer for dynamic station/tablet pairing, atomic ticket
-- claiming, cross-device notes, checklist descriptions, and inline photo evidence.

BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('public.jwt_tenant_id()') IS NULL
     OR to_regprocedure('public.orbit_has_capability(text,uuid)') IS NULL
     OR to_regclass('public.audit_worm_ledger') IS NULL THEN
    RAISE EXCEPTION 'BAY_PREFLIGHT_FAILED: tenant, capability, or WORM prerequisites are missing';
  END IF;
END
$preflight$;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

-- Register fixed cart/workstation clients without binding any tablet to them.
ALTER TABLE public.trusted_hardware
  DROP CONSTRAINT IF EXISTS trusted_hardware_device_type_check;
ALTER TABLE public.trusted_hardware
  ADD CONSTRAINT trusted_hardware_device_type_check CHECK (
    device_type = ANY (ARRAY[
      'Pilot_Tablet'::text,
      'Bay_Tablet'::text,
      'Bay_Hub'::text,
      'Bay_Workstation'::text,
      'Node_Phone'::text,
      'Driver_BYOD'::text,
      'Satellite_Tablet'::text
    ])
  );

CREATE SEQUENCE IF NOT EXISTS public.bay_ticket_number_seq AS bigint START WITH 1000;

CREATE TABLE IF NOT EXISTS public.bay_tenant_settings (
  id uuid NOT NULL DEFAULT uuid_generate_v4() UNIQUE,
  tenant_id uuid PRIMARY KEY REFERENCES public.districts(id) ON DELETE RESTRICT,
  operation_model text NOT NULL DEFAULT 'IN_HOUSE'
    CHECK (operation_model IN ('IN_HOUSE', 'OUTSOURCED')),
  maintenance_contractor_id uuid REFERENCES public.contractors(id) ON DELETE RESTRICT,
  pairing_lease_hours smallint NOT NULL DEFAULT 12
    CHECK (pairing_lease_hours BETWEEN 1 AND 24),
  max_photos_per_checkpoint smallint NOT NULL DEFAULT 8
    CHECK (max_photos_per_checkpoint BETWEEN 1 AND 20),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_tenant_settings_model_check CHECK (
    operation_model <> 'OUTSOURCED' OR maintenance_contractor_id IS NOT NULL
  )
);

CREATE TABLE IF NOT EXISTS public.bay_staff_authorizations (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  staff_id uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  may_use_hub boolean NOT NULL DEFAULT false,
  may_schedule_maintenance boolean NOT NULL DEFAULT false,
  may_change_service_status boolean NOT NULL DEFAULT false,
  is_supervisor boolean NOT NULL DEFAULT false,
  granted_by uuid REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  valid_until timestamptz,
  revoked_at timestamptz,
  revoked_by uuid REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_staff_authorizations_tenant_staff_unique UNIQUE (tenant_id, staff_id),
  CONSTRAINT bay_staff_authorizations_revoke_check CHECK (
    (revoked_at IS NULL AND revoked_by IS NULL)
    OR (revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.bay_hubs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  hardware_id uuid NOT NULL UNIQUE
    REFERENCES public.trusted_hardware(id) ON DELETE RESTRICT,
  hub_code text NOT NULL,
  display_name text NOT NULL,
  bay_location text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_hubs_code_check CHECK (btrim(hub_code) <> ''),
  CONSTRAINT bay_hubs_name_check CHECK (btrim(display_name) <> ''),
  CONSTRAINT bay_hubs_tenant_code_unique UNIQUE (tenant_id, hub_code)
);

CREATE TABLE IF NOT EXISTS public.bay_hub_sessions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  hub_id uuid NOT NULL REFERENCES public.bay_hubs(id) ON DELETE RESTRICT,
  operator_id uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  session_state text NOT NULL DEFAULT 'ACTIVE'
    CHECK (session_state IN ('ACTIVE', 'ENDED', 'EXPIRED', 'REPLACED')),
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_expires_at timestamptz NOT NULL,
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_hub_sessions_end_check CHECK (
    (session_state = 'ACTIVE' AND ended_at IS NULL)
    OR (session_state IN ('ENDED', 'EXPIRED', 'REPLACED') AND ended_at IS NOT NULL)
  ),
  CONSTRAINT bay_hub_sessions_lease_check CHECK (lease_expires_at > started_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS bay_one_active_session_per_hub
  ON public.bay_hub_sessions(hub_id) WHERE session_state = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS bay_one_active_hub_session_per_operator
  ON public.bay_hub_sessions(operator_id) WHERE session_state = 'ACTIVE';
CREATE INDEX IF NOT EXISTS bay_hub_sessions_tenant_last_seen_idx
  ON public.bay_hub_sessions(tenant_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS public.bay_workstations (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  hardware_id uuid NOT NULL UNIQUE
    REFERENCES public.trusted_hardware(id) ON DELETE RESTRICT,
  station_code text NOT NULL,
  display_name text NOT NULL,
  bay_location text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_workstations_station_code_check CHECK (btrim(station_code) <> ''),
  CONSTRAINT bay_workstations_display_name_check CHECK (btrim(display_name) <> ''),
  CONSTRAINT bay_workstations_tenant_code_unique UNIQUE (tenant_id, station_code)
);

CREATE TABLE IF NOT EXISTS public.bay_work_sessions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  technician_id uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  workstation_id uuid NOT NULL REFERENCES public.bay_workstations(id) ON DELETE RESTRICT,
  tablet_hardware_id uuid NOT NULL REFERENCES public.trusted_hardware(id) ON DELETE RESTRICT,
  previous_session_id uuid REFERENCES public.bay_work_sessions(id) ON DELETE SET NULL,
  current_work_order_id uuid REFERENCES public.maintenance_work_orders(id) ON DELETE SET NULL,
  pairing_method text NOT NULL DEFAULT 'DOCK'
    CHECK (pairing_method IN ('DOCK', 'NEARBY', 'QR_RECOVERY', 'MANUAL_RECOVERY')),
  session_state text NOT NULL DEFAULT 'ACTIVE'
    CHECK (session_state IN ('ACTIVE', 'DISCONNECTED', 'REPLACED', 'ENDED', 'EXPIRED')),
  paired_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_expires_at timestamptz NOT NULL,
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_work_sessions_end_state_check CHECK (
    (session_state IN ('ACTIVE', 'DISCONNECTED') AND ended_at IS NULL)
    OR (session_state IN ('REPLACED', 'ENDED', 'EXPIRED') AND ended_at IS NOT NULL)
  ),
  CONSTRAINT bay_work_sessions_lease_check CHECK (lease_expires_at > paired_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS bay_one_active_session_per_station
  ON public.bay_work_sessions(workstation_id)
  WHERE session_state IN ('ACTIVE', 'DISCONNECTED');
CREATE UNIQUE INDEX IF NOT EXISTS bay_one_active_session_per_tablet
  ON public.bay_work_sessions(tablet_hardware_id)
  WHERE session_state IN ('ACTIVE', 'DISCONNECTED');
CREATE UNIQUE INDEX IF NOT EXISTS bay_one_active_session_per_technician
  ON public.bay_work_sessions(technician_id)
  WHERE session_state IN ('ACTIVE', 'DISCONNECTED');
CREATE INDEX IF NOT EXISTS bay_work_sessions_tenant_last_seen_idx
  ON public.bay_work_sessions(tenant_id, last_seen_at DESC);

ALTER TABLE public.maintenance_work_orders
  ADD COLUMN IF NOT EXISTS ticket_number bigint,
  ADD COLUMN IF NOT EXISTS claimed_by_id uuid REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS claim_session_id uuid,
  ADD COLUMN IF NOT EXISTS lock_version bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS last_activity_at timestamptz NOT NULL DEFAULT clock_timestamp();

UPDATE public.maintenance_work_orders
SET ticket_number = nextval('public.bay_ticket_number_seq')
WHERE ticket_number IS NULL;

ALTER TABLE public.maintenance_work_orders
  ALTER COLUMN ticket_number SET DEFAULT nextval('public.bay_ticket_number_seq'),
  ALTER COLUMN ticket_number SET NOT NULL;

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'maintenance_work_orders_claim_session_fkey'
      AND conrelid = 'public.maintenance_work_orders'::regclass
  ) THEN
    ALTER TABLE public.maintenance_work_orders
      ADD CONSTRAINT maintenance_work_orders_claim_session_fkey
      FOREIGN KEY (claim_session_id)
      REFERENCES public.bay_work_sessions(id) ON DELETE SET NULL;
  END IF;
END
$constraint$;

CREATE UNIQUE INDEX IF NOT EXISTS maintenance_work_orders_tenant_ticket_unique
  ON public.maintenance_work_orders(tenant_id, ticket_number);
CREATE INDEX IF NOT EXISTS maintenance_work_orders_pull_screen_idx
  ON public.maintenance_work_orders(tenant_id, priority, created_at)
  WHERE status = 'Open' AND claimed_by_id IS NULL;
CREATE INDEX IF NOT EXISTS maintenance_work_orders_assignee_idx
  ON public.maintenance_work_orders(tenant_id, assigned_crew_id, status);

ALTER TABLE public.bus_inspections
  ADD COLUMN IF NOT EXISTS work_order_id uuid
    REFERENCES public.maintenance_work_orders(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS trip_id uuid REFERENCES public.trips(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_system text NOT NULL DEFAULT 'BAY_WORKSTATION',
  ADD COLUMN IF NOT EXISTS source_device_id uuid
    REFERENCES public.trusted_hardware(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_by uuid
    REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
  ADD COLUMN IF NOT EXISTS sync_received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ADD COLUMN IF NOT EXISTS lock_version bigint NOT NULL DEFAULT 1;

ALTER TABLE public.bus_inspections
  DROP CONSTRAINT IF EXISTS bus_inspections_inspection_type_check;
ALTER TABLE public.bus_inspections
  ADD CONSTRAINT bus_inspections_inspection_type_check CHECK (
    inspection_type IN ('Pre_Trip', 'Mid_Trip', 'Post_Trip', 'Bay_Review', 'DOT_Audit')
  );

DO $inspection_source_constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'bus_inspections_source_system_check'
      AND conrelid = 'public.bus_inspections'::regclass
  ) THEN
    ALTER TABLE public.bus_inspections
      ADD CONSTRAINT bus_inspections_source_system_check CHECK (
        source_system IN ('PILOT_APP', 'BAY_TABLET', 'BAY_WORKSTATION', 'BAY_HUB', 'EXTERNAL_IMPORT')
      );
  END IF;
END
$inspection_source_constraint$;

CREATE INDEX IF NOT EXISTS bus_inspections_work_order_idx
  ON public.bus_inspections(tenant_id, work_order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS bus_inspections_trip_catalog_idx
  ON public.bus_inspections(tenant_id, bus_id, trip_id, inspection_type, created_at DESC);

CREATE TABLE IF NOT EXISTS public.bay_maintenance_schedules (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  bus_id uuid NOT NULL REFERENCES public.buses(id) ON DELETE RESTRICT,
  work_order_id uuid REFERENCES public.maintenance_work_orders(id) ON DELETE SET NULL,
  maintenance_type text NOT NULL,
  description text NOT NULL CHECK (btrim(description) <> ''),
  scheduled_start_at timestamptz NOT NULL,
  scheduled_end_at timestamptz,
  due_odometer integer CHECK (due_odometer IS NULL OR due_odometer >= 0),
  down_vehicle_at_start boolean NOT NULL DEFAULT false,
  schedule_status text NOT NULL DEFAULT 'SCHEDULED'
    CHECK (schedule_status IN ('SCHEDULED', 'DUE', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  created_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  hub_session_id uuid NOT NULL REFERENCES public.bay_hub_sessions(id) ON DELETE RESTRICT,
  credential_verified_at timestamptz NOT NULL,
  auth_session_id text NOT NULL,
  client_mutation_id uuid NOT NULL DEFAULT uuid_generate_v4(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_schedule_window_check CHECK (
    scheduled_end_at IS NULL OR scheduled_end_at > scheduled_start_at
  ),
  CONSTRAINT bay_schedule_type_check CHECK (btrim(maintenance_type) <> ''),
  CONSTRAINT bay_schedule_mutation_unique UNIQUE (tenant_id, client_mutation_id)
);

CREATE INDEX IF NOT EXISTS bay_maintenance_schedule_due_idx
  ON public.bay_maintenance_schedules(tenant_id, scheduled_start_at)
  WHERE schedule_status IN ('SCHEDULED', 'DUE');
CREATE INDEX IF NOT EXISTS bay_maintenance_schedule_bus_idx
  ON public.bay_maintenance_schedules(tenant_id, bus_id, scheduled_start_at DESC);

CREATE TABLE IF NOT EXISTS public.bay_vehicle_service_events (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES public.districts(id) ON DELETE RESTRICT,
  bus_id uuid NOT NULL REFERENCES public.buses(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('DOWNED', 'RETURNED_TO_SERVICE')),
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  requested_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  authorized_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  supervisor_override boolean NOT NULL DEFAULT false,
  override_reason text,
  hub_id uuid NOT NULL REFERENCES public.bay_hubs(id) ON DELETE RESTRICT,
  hub_session_id uuid NOT NULL REFERENCES public.bay_hub_sessions(id) ON DELETE RESTRICT,
  credential_verified_at timestamptz NOT NULL,
  auth_session_id text NOT NULL,
  prior_vehicle_state jsonb NOT NULL,
  resulting_vehicle_state jsonb NOT NULL,
  open_safety_blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_service_override_check CHECK (
    (NOT supervisor_override AND override_reason IS NULL)
    OR (supervisor_override AND btrim(override_reason) <> '')
  )
);

CREATE INDEX IF NOT EXISTS bay_vehicle_service_events_bus_idx
  ON public.bay_vehicle_service_events(tenant_id, bus_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS public.bay_work_order_notes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  work_order_id uuid NOT NULL
    REFERENCES public.maintenance_work_orders(id) ON DELETE RESTRICT,
  note_type text NOT NULL DEFAULT 'GENERAL'
    CHECK (note_type IN ('GENERAL', 'DIAGNOSIS', 'PROGRESS', 'PARTS', 'RESOLUTION')),
  body text NOT NULL CHECK (btrim(body) <> ''),
  created_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  last_edited_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  source_session_id uuid REFERENCES public.bay_work_sessions(id) ON DELETE SET NULL,
  client_mutation_id uuid NOT NULL DEFAULT uuid_generate_v4(),
  lock_version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_work_order_notes_mutation_unique UNIQUE (tenant_id, client_mutation_id)
);

CREATE INDEX IF NOT EXISTS bay_work_order_notes_order_idx
  ON public.bay_work_order_notes(tenant_id, work_order_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.bay_inspection_checkpoints (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  inspection_id uuid NOT NULL REFERENCES public.bus_inspections(id) ON DELETE RESTRICT,
  work_order_id uuid REFERENCES public.maintenance_work_orders(id) ON DELETE SET NULL,
  item_code text NOT NULL,
  item_label text NOT NULL,
  component_area text,
  prompt text,
  description text,
  result text NOT NULL DEFAULT 'NOT_CHECKED'
    CHECK (result IN ('NOT_CHECKED', 'PASS', 'FAIL', 'NEEDS_ATTENTION', 'NOT_APPLICABLE')),
  is_cosmetic boolean NOT NULL DEFAULT false,
  sequence_number integer NOT NULL CHECK (sequence_number >= 0),
  completed_by uuid REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  completed_at timestamptz,
  source_session_id uuid REFERENCES public.bay_work_sessions(id) ON DELETE SET NULL,
  client_mutation_id uuid NOT NULL DEFAULT uuid_generate_v4(),
  lock_version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_checkpoint_item_check CHECK (btrim(item_code) <> '' AND btrim(item_label) <> ''),
  CONSTRAINT bay_checkpoint_completion_check CHECK (
    (result = 'NOT_CHECKED' AND completed_at IS NULL)
    OR (result <> 'NOT_CHECKED' AND completed_at IS NOT NULL)
  ),
  CONSTRAINT bay_checkpoint_item_unique UNIQUE (inspection_id, item_code),
  CONSTRAINT bay_checkpoint_mutation_unique UNIQUE (tenant_id, client_mutation_id)
);

CREATE INDEX IF NOT EXISTS bay_checkpoints_inspection_sequence_idx
  ON public.bay_inspection_checkpoints(tenant_id, inspection_id, sequence_number);
CREATE INDEX IF NOT EXISTS bay_checkpoints_work_order_idx
  ON public.bay_inspection_checkpoints(tenant_id, work_order_id);

CREATE TABLE IF NOT EXISTS public.bay_inspection_media (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL DEFAULT public.jwt_tenant_id()
    REFERENCES public.districts(id) ON DELETE RESTRICT,
  checkpoint_id uuid NOT NULL
    REFERENCES public.bay_inspection_checkpoints(id) ON DELETE RESTRICT,
  storage_bucket text NOT NULL DEFAULT 'bay-inspection-media'
    CHECK (storage_bucket = 'bay-inspection-media'),
  object_path text NOT NULL UNIQUE,
  caption text,
  mime_type text NOT NULL
    CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp', 'image/heic')),
  byte_size bigint NOT NULL CHECK (byte_size > 0 AND byte_size <= 20971520),
  sha256_hex text NOT NULL CHECK (sha256_hex ~ '^[0-9a-f]{64}$'),
  pixel_width integer CHECK (pixel_width IS NULL OR pixel_width > 0),
  pixel_height integer CHECK (pixel_height IS NULL OR pixel_height > 0),
  captured_by uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  captured_device_id uuid REFERENCES public.trusted_hardware(id) ON DELETE SET NULL,
  captured_at timestamptz NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  client_mutation_id uuid NOT NULL DEFAULT uuid_generate_v4(),
  voided_at timestamptz,
  voided_by uuid REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  void_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bay_media_path_check CHECK (
    object_path = tenant_id::text || '/' || checkpoint_id::text || '/' || id::text ||
      CASE mime_type
        WHEN 'image/jpeg' THEN '.jpg'
        WHEN 'image/png' THEN '.png'
        WHEN 'image/webp' THEN '.webp'
        WHEN 'image/heic' THEN '.heic'
      END
  ),
  CONSTRAINT bay_media_void_check CHECK (
    (voided_at IS NULL AND voided_by IS NULL AND void_reason IS NULL)
    OR (voided_at IS NOT NULL AND voided_by IS NOT NULL AND btrim(void_reason) <> '')
  ),
  CONSTRAINT bay_media_mutation_unique UNIQUE (tenant_id, client_mutation_id)
);

CREATE INDEX IF NOT EXISTS bay_media_checkpoint_idx
  ON public.bay_inspection_media(tenant_id, checkpoint_id, captured_at);

CREATE OR REPLACE FUNCTION private.bay_user_is_manager(p_user_id uuid, p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH me AS (
    SELECT sp.role, sp.contractor_id
    FROM public.staff_profiles sp
    WHERE sp.id = p_user_id
      AND sp.tenant_id = p_tenant_id
      AND sp.is_active
      AND sp.archived_at IS NULL
  ), cfg AS (
    SELECT s.operation_model, s.maintenance_contractor_id
    FROM public.bay_tenant_settings s
    WHERE s.tenant_id = p_tenant_id
  )
  SELECT EXISTS (
    SELECT 1
    FROM me
    LEFT JOIN cfg ON true
    WHERE CASE COALESCE(cfg.operation_model, 'IN_HOUSE')
      WHEN 'OUTSOURCED' THEN
        me.role IN ('Crew', 'Control')
        AND me.contractor_id = cfg.maintenance_contractor_id
      ELSE me.role IN ('Crew', 'Command', 'Central', 'Superintendent')
    END
  )
$function$;

CREATE OR REPLACE FUNCTION private.bay_user_has_hub_authorization(
  p_user_id uuid,
  p_tenant_id uuid,
  p_permission text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT private.bay_user_is_manager(p_user_id, p_tenant_id)
    AND EXISTS (
      SELECT 1
      FROM public.bay_staff_authorizations a
      WHERE a.staff_id = p_user_id
        AND a.tenant_id = p_tenant_id
        AND a.revoked_at IS NULL
        AND (a.valid_until IS NULL OR a.valid_until > clock_timestamp())
        AND CASE p_permission
          WHEN 'HUB_LOGIN' THEN a.may_use_hub
          WHEN 'SCHEDULE_MAINTENANCE' THEN a.may_use_hub AND a.may_schedule_maintenance
          WHEN 'CHANGE_SERVICE_STATUS' THEN a.may_use_hub AND a.may_change_service_status
          WHEN 'SUPERVISOR_OVERRIDE' THEN a.may_use_hub AND a.is_supervisor
          ELSE false
        END
    )
$function$;

CREATE OR REPLACE FUNCTION private.bay_fresh_credential_time(p_max_age_seconds integer DEFAULT 300)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_auth_time timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NULLIF(auth.jwt() ->> 'session_id', '') IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_max_age_seconds < 30 OR p_max_age_seconds > 900 THEN
    RAISE EXCEPTION 'BAY_INVALID_CREDENTIAL_WINDOW' USING ERRCODE = '22023';
  END IF;

  SELECT to_timestamp(MAX((entry ->> 'timestamp')::bigint))
  INTO v_auth_time
  FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) AS amr(entry)
  WHERE entry ->> 'method' IN ('password', 'totp', 'sso/saml');

  IF v_auth_time IS NULL
     OR v_auth_time < clock_timestamp() - make_interval(secs => p_max_age_seconds) THEN
    RAISE EXCEPTION 'BAY_FRESH_CREDENTIALS_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN v_auth_time;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_pilot_can_contribute_inspection(
  p_inspection_id uuid,
  p_tenant_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND public.jwt_tenant_id() = p_tenant_id
    AND EXISTS (
      SELECT 1
      FROM public.bus_inspections bi
      JOIN public.buses b ON b.id = bi.bus_id
      WHERE bi.id = p_inspection_id
        AND bi.tenant_id = p_tenant_id
        AND bi.inspector_id = auth.uid()
        AND b.assigned_pilot_id = auth.uid()
        AND (SELECT public.get_my_role()) IN ('Pilot', 'Halo')
    )
$function$;

CREATE OR REPLACE FUNCTION private.bay_can_view_tenant(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND p_tenant_id IS NOT NULL
    AND public.jwt_tenant_id() = p_tenant_id
    AND public.orbit_has_capability('BAY', p_tenant_id)
    AND EXISTS (
      SELECT 1
      FROM public.staff_profiles sp
      WHERE sp.id = auth.uid()
        AND sp.tenant_id = p_tenant_id
        AND sp.is_active
        AND sp.archived_at IS NULL
        AND sp.role IN (
          'Crew', 'Control', 'Command', 'Central', 'Superintendent', 'Principal'
        )
    )
$function$;

CREATE OR REPLACE FUNCTION private.bay_can_manage_tenant(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND p_tenant_id IS NOT NULL
    AND public.jwt_tenant_id() = p_tenant_id
    AND public.orbit_has_capability('BAY', p_tenant_id)
    AND private.bay_user_is_manager(auth.uid(), p_tenant_id)
$function$;

CREATE OR REPLACE FUNCTION private.bay_can_contribute_checkpoint(
  p_checkpoint_id uuid,
  p_tenant_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT private.bay_can_manage_tenant(p_tenant_id)
    OR EXISTS (
      SELECT 1
      FROM public.bay_inspection_checkpoints cp
      WHERE cp.id = p_checkpoint_id
        AND cp.tenant_id = p_tenant_id
        AND private.bay_pilot_can_contribute_inspection(cp.inspection_id, p_tenant_id)
    )
$function$;

REVOKE ALL ON FUNCTION private.bay_user_is_manager(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_user_has_hub_authorization(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_fresh_credential_time(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_pilot_can_contribute_inspection(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_can_contribute_checkpoint(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_can_view_tenant(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_can_manage_tenant(uuid) FROM PUBLIC, anon, authenticated;

-- RLS and Storage policy expressions execute in the caller's authorization
-- context. Expose only these boolean evaluators to authenticated sessions; the
-- private schema remains outside the API surface and all mutation helpers stay
-- revoked.
GRANT EXECUTE ON FUNCTION private.bay_pilot_can_contribute_inspection(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_contribute_checkpoint(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_view_tenant(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION private.bay_can_manage_tenant(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION private.bay_validate_row_links()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_related_tenant uuid;
BEGIN
  IF TG_TABLE_NAME = 'bay_staff_authorizations' THEN
    SELECT sp.tenant_id INTO v_related_tenant
    FROM public.staff_profiles sp
    WHERE sp.id = NEW.staff_id
      AND sp.is_active
      AND sp.archived_at IS NULL;
  ELSIF TG_TABLE_NAME = 'bay_hubs' THEN
    SELECT th.tenant_id INTO v_related_tenant
    FROM public.trusted_hardware th
    WHERE th.id = NEW.hardware_id
      AND th.device_type = 'Bay_Hub'
      AND th.is_active;
  ELSIF TG_TABLE_NAME = 'bay_workstations' THEN
    SELECT th.tenant_id INTO v_related_tenant
    FROM public.trusted_hardware th
    WHERE th.id = NEW.hardware_id
      AND th.device_type = 'Bay_Workstation'
      AND th.is_active;
  ELSIF TG_TABLE_NAME = 'bay_work_order_notes' THEN
    SELECT wo.tenant_id INTO v_related_tenant
    FROM public.maintenance_work_orders wo
    WHERE wo.id = NEW.work_order_id;
  ELSIF TG_TABLE_NAME = 'bay_inspection_checkpoints' THEN
    SELECT bi.tenant_id INTO v_related_tenant
    FROM public.bus_inspections bi
    WHERE bi.id = NEW.inspection_id;
    IF NEW.work_order_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.maintenance_work_orders wo
      WHERE wo.id = NEW.work_order_id AND wo.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION 'BAY_TENANT_LINK_MISMATCH' USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'bay_inspection_media' THEN
    SELECT cp.tenant_id INTO v_related_tenant
    FROM public.bay_inspection_checkpoints cp
    WHERE cp.id = NEW.checkpoint_id;
  ELSIF TG_TABLE_NAME = 'bay_maintenance_schedules' THEN
    SELECT b.tenant_id INTO v_related_tenant
    FROM public.buses b
    WHERE b.id = NEW.bus_id;
    IF NOT EXISTS (
      SELECT 1 FROM public.bay_hub_sessions hs
      WHERE hs.id = NEW.hub_session_id
        AND hs.tenant_id = NEW.tenant_id
        AND hs.operator_id = NEW.created_by
    ) THEN
      RAISE EXCEPTION 'BAY_HUB_SESSION_LINK_MISMATCH' USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'bay_vehicle_service_events' THEN
    SELECT b.tenant_id INTO v_related_tenant
    FROM public.buses b
    WHERE b.id = NEW.bus_id;
  END IF;

  IF v_related_tenant IS NULL OR v_related_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'BAY_TENANT_LINK_MISMATCH' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_validate_hub_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF ROW(NEW.tenant_id, NEW.hub_id, NEW.operator_id, NEW.started_at)
       IS DISTINCT FROM ROW(OLD.tenant_id, OLD.hub_id, OLD.operator_id, OLD.started_at) THEN
      RAISE EXCEPTION 'BAY_HUB_SESSION_BINDING_IMMUTABLE' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.bay_hubs h
    WHERE h.id = NEW.hub_id
      AND h.tenant_id = NEW.tenant_id
      AND h.is_active
  ) OR NOT private.bay_user_has_hub_authorization(
    NEW.operator_id, NEW.tenant_id, 'HUB_LOGIN'
  ) THEN
    RAISE EXCEPTION 'BAY_HUB_SESSION_BINDING_INVALID' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_validate_work_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.bay_workstations ws
    WHERE ws.id = NEW.workstation_id
      AND ws.tenant_id = NEW.tenant_id
      AND ws.is_active
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.trusted_hardware th
    WHERE th.id = NEW.tablet_hardware_id
      AND th.tenant_id = NEW.tenant_id
      AND th.device_type = 'Bay_Tablet'
      AND th.is_active
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.staff_profiles sp
    WHERE sp.id = NEW.technician_id
      AND sp.tenant_id = NEW.tenant_id
      AND sp.is_active
      AND sp.archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'BAY_SESSION_BINDING_INVALID' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_bump_lock_version()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  NEW.lock_version := OLD.lock_version + 1;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_prepare_new_work_order()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF current_setting('role', true) = 'authenticated' THEN
    NEW.tenant_id := public.jwt_tenant_id();
    NEW.reported_by_id := auth.uid();
    NEW.assigned_crew_id := NULL;
    NEW.claimed_by_id := NULL;
    NEW.claimed_at := NULL;
    NEW.claim_session_id := NULL;
    NEW.lock_version := 1;
  END IF;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_media_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF ROW(
    NEW.tenant_id, NEW.checkpoint_id, NEW.storage_bucket, NEW.object_path,
    NEW.mime_type, NEW.byte_size, NEW.sha256_hex, NEW.captured_by,
    NEW.captured_device_id, NEW.captured_at, NEW.uploaded_at, NEW.client_mutation_id
  ) IS DISTINCT FROM ROW(
    OLD.tenant_id, OLD.checkpoint_id, OLD.storage_bucket, OLD.object_path,
    OLD.mime_type, OLD.byte_size, OLD.sha256_hex, OLD.captured_by,
    OLD.captured_device_id, OLD.captured_at, OLD.uploaded_at, OLD.client_mutation_id
  ) THEN
    RAISE EXCEPTION 'BAY_MEDIA_EVIDENCE_FIELDS_ARE_IMMUTABLE' USING ERRCODE = '42501';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION private.bay_worm_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_row jsonb := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  v_tenant uuid := NULLIF(v_row ->> 'tenant_id', '')::uuid;
  v_id uuid := NULLIF(v_row ->> 'id', '')::uuid;
BEGIN
  INSERT INTO public.audit_worm_ledger(
    tenant_id, actor_id, action_type, source_table, source_record_id,
    old_row, new_row, jwt_tenant_id
  ) VALUES (
    v_tenant,
    auth.uid(),
    'BAY_' || TG_OP,
    TG_TABLE_NAME,
    v_id,
    CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
    public.jwt_tenant_id()
  );
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION private.bay_validate_row_links() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_validate_work_session() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_validate_hub_session() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_bump_lock_version() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_prepare_new_work_order() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_media_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.bay_worm_log() FROM PUBLIC, anon, authenticated;

DO $triggers$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'bay_tenant_settings',
    'bay_staff_authorizations',
    'bay_hubs',
    'bay_hub_sessions',
    'bay_workstations',
    'bay_work_sessions',
    'bay_maintenance_schedules',
    'bay_vehicle_service_events',
    'bay_work_order_notes',
    'bay_inspection_checkpoints',
    'bay_inspection_media'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trig_duval_stamp_tenant ON public.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trig_duval_stamp_tenant BEFORE INSERT OR UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.duval_stamp_tenant_id()', t
    );
    EXECUTE format('DROP TRIGGER IF EXISTS trig_audit_%I ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trig_audit_%I AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.process_forensic_audit()', t, t
    );
    EXECUTE format('DROP TRIGGER IF EXISTS trig_worm_%I ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trig_worm_%I AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION private.bay_worm_log()', t, t
    );
  END LOOP;

  FOREACH t IN ARRAY ARRAY['maintenance_work_orders', 'bus_inspections']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trig_worm_%I ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trig_worm_%I AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION private.bay_worm_log()', t, t
    );
  END LOOP;
END
$triggers$;

DO $timestamps$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'bay_tenant_settings',
    'bay_staff_authorizations',
    'bay_hubs',
    'bay_hub_sessions',
    'bay_workstations',
    'bay_work_sessions',
    'bay_maintenance_schedules'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trig_set_updated_%I ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trig_set_updated_%I BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t, t
    );
  END LOOP;
END
$timestamps$;

DROP TRIGGER IF EXISTS trig_bay_validate_staff_authorization ON public.bay_staff_authorizations;
CREATE TRIGGER trig_bay_validate_staff_authorization
BEFORE INSERT OR UPDATE ON public.bay_staff_authorizations
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_hub ON public.bay_hubs;
CREATE TRIGGER trig_bay_validate_hub
BEFORE INSERT OR UPDATE ON public.bay_hubs
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_hub_session ON public.bay_hub_sessions;
CREATE TRIGGER trig_bay_validate_hub_session
BEFORE INSERT OR UPDATE ON public.bay_hub_sessions
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_hub_session();

DROP TRIGGER IF EXISTS trig_bay_validate_workstation ON public.bay_workstations;
CREATE TRIGGER trig_bay_validate_workstation
BEFORE INSERT OR UPDATE ON public.bay_workstations
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_prepare_new_work_order ON public.maintenance_work_orders;
CREATE TRIGGER trig_bay_prepare_new_work_order
BEFORE INSERT ON public.maintenance_work_orders
FOR EACH ROW EXECUTE FUNCTION private.bay_prepare_new_work_order();

DROP TRIGGER IF EXISTS trig_bay_validate_session ON public.bay_work_sessions;
CREATE TRIGGER trig_bay_validate_session
BEFORE INSERT OR UPDATE ON public.bay_work_sessions
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_work_session();

DROP TRIGGER IF EXISTS trig_bay_validate_note ON public.bay_work_order_notes;
CREATE TRIGGER trig_bay_validate_note
BEFORE INSERT OR UPDATE ON public.bay_work_order_notes
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_checkpoint ON public.bay_inspection_checkpoints;
CREATE TRIGGER trig_bay_validate_checkpoint
BEFORE INSERT OR UPDATE ON public.bay_inspection_checkpoints
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_media ON public.bay_inspection_media;
CREATE TRIGGER trig_bay_validate_media
BEFORE INSERT ON public.bay_inspection_media
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_schedule ON public.bay_maintenance_schedules;
CREATE TRIGGER trig_bay_validate_schedule
BEFORE INSERT OR UPDATE ON public.bay_maintenance_schedules
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_validate_service_event ON public.bay_vehicle_service_events;
CREATE TRIGGER trig_bay_validate_service_event
BEFORE INSERT ON public.bay_vehicle_service_events
FOR EACH ROW EXECUTE FUNCTION private.bay_validate_row_links();

DROP TRIGGER IF EXISTS trig_bay_deny_service_event_mutation ON public.bay_vehicle_service_events;
CREATE TRIGGER trig_bay_deny_service_event_mutation
BEFORE UPDATE OR DELETE ON public.bay_vehicle_service_events
FOR EACH ROW EXECUTE FUNCTION public.deny_worm_mutation();

DROP TRIGGER IF EXISTS trig_bay_media_guard ON public.bay_inspection_media;
CREATE TRIGGER trig_bay_media_guard
BEFORE UPDATE ON public.bay_inspection_media
FOR EACH ROW EXECUTE FUNCTION private.bay_media_guard();

DO $versions$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'maintenance_work_orders',
    'bus_inspections',
    'bay_work_order_notes',
    'bay_inspection_checkpoints'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trig_bay_version_%I ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trig_bay_version_%I BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION private.bay_bump_lock_version()', t, t
    );
  END LOOP;
END
$versions$;

-- Existing Bay tables had a permissive tenant-only ALL policy. Replace it with
-- capability- and role-aware policies before granting write access.
DROP POLICY IF EXISTS duval_tenant_isolation ON public.maintenance_work_orders;
DROP POLICY IF EXISTS crew_view_work_orders ON public.maintenance_work_orders;
DROP POLICY IF EXISTS bay_work_orders_read ON public.maintenance_work_orders;
DROP POLICY IF EXISTS bay_work_orders_insert ON public.maintenance_work_orders;
DROP POLICY IF EXISTS bay_work_orders_update ON public.maintenance_work_orders;
CREATE POLICY bay_work_orders_read ON public.maintenance_work_orders
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));
CREATE POLICY bay_work_orders_insert ON public.maintenance_work_orders
  FOR INSERT TO authenticated
  WITH CHECK (private.bay_can_manage_tenant(tenant_id));
CREATE POLICY bay_work_orders_update ON public.maintenance_work_orders
  FOR UPDATE TO authenticated
  USING (private.bay_can_manage_tenant(tenant_id))
  WITH CHECK (private.bay_can_manage_tenant(tenant_id));

DROP POLICY IF EXISTS duval_tenant_isolation ON public.bus_inspections;
DROP POLICY IF EXISTS crew_manage_inspections ON public.bus_inspections;
DROP POLICY IF EXISTS bay_inspections_read ON public.bus_inspections;
DROP POLICY IF EXISTS bay_inspections_insert ON public.bus_inspections;
DROP POLICY IF EXISTS bay_inspections_update ON public.bus_inspections;
CREATE POLICY bay_inspections_read ON public.bus_inspections
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));
CREATE POLICY bay_inspections_insert ON public.bus_inspections
  FOR INSERT TO authenticated
  WITH CHECK (private.bay_can_manage_tenant(tenant_id));
CREATE POLICY bay_inspections_update ON public.bus_inspections
  FOR UPDATE TO authenticated
  USING (private.bay_can_manage_tenant(tenant_id))
  WITH CHECK (private.bay_can_manage_tenant(tenant_id));

DROP POLICY IF EXISTS bay_pilot_inspections_read ON public.bus_inspections;
CREATE POLICY bay_pilot_inspections_read ON public.bus_inspections
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.jwt_tenant_id()
    AND inspector_id = auth.uid()
    AND (SELECT public.get_my_role()) IN ('Pilot', 'Halo')
    AND EXISTS (
      SELECT 1 FROM public.buses b
      WHERE b.id = bus_id AND b.assigned_pilot_id = auth.uid()
    )
  );
DROP POLICY IF EXISTS bay_pilot_inspections_insert ON public.bus_inspections;
CREATE POLICY bay_pilot_inspections_insert ON public.bus_inspections
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = public.jwt_tenant_id()
    AND inspector_id = auth.uid()
    AND submitted_by = auth.uid()
    AND source_system = 'PILOT_APP'
    AND (SELECT public.get_my_role()) IN ('Pilot', 'Halo')
    AND EXISTS (
      SELECT 1 FROM public.buses b
      WHERE b.id = bus_id
        AND b.tenant_id = tenant_id
        AND b.assigned_pilot_id = auth.uid()
    )
  );
DROP POLICY IF EXISTS bay_pilot_inspections_update ON public.bus_inspections;
CREATE POLICY bay_pilot_inspections_update ON public.bus_inspections
  FOR UPDATE TO authenticated
  USING (
    tenant_id = public.jwt_tenant_id()
    AND inspector_id = auth.uid()
    AND submitted_by = auth.uid()
    AND source_system = 'PILOT_APP'
    AND inspection_status = 'In_Progress'
  )
  WITH CHECK (
    tenant_id = public.jwt_tenant_id()
    AND inspector_id = auth.uid()
    AND submitted_by = auth.uid()
    AND source_system = 'PILOT_APP'
  );

DO $rls$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'bay_tenant_settings',
    'bay_staff_authorizations',
    'bay_hubs',
    'bay_hub_sessions',
    'bay_workstations',
    'bay_work_sessions',
    'bay_maintenance_schedules',
    'bay_vehicle_service_events',
    'bay_work_order_notes',
    'bay_inspection_checkpoints',
    'bay_inspection_media'
  ]
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS bay_deny_anon ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY bay_deny_anon ON public.%I AS RESTRICTIVE FOR ALL TO anon '
      'USING (false) WITH CHECK (false)', t
    );
  END LOOP;
END
$rls$;

DROP POLICY IF EXISTS bay_settings_read ON public.bay_tenant_settings;
CREATE POLICY bay_settings_read ON public.bay_tenant_settings
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));

DROP POLICY IF EXISTS bay_staff_authorizations_read ON public.bay_staff_authorizations;
CREATE POLICY bay_staff_authorizations_read ON public.bay_staff_authorizations
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.jwt_tenant_id()
    AND (staff_id = auth.uid() OR private.bay_can_view_tenant(tenant_id))
  );

DROP POLICY IF EXISTS bay_hubs_read ON public.bay_hubs;
CREATE POLICY bay_hubs_read ON public.bay_hubs
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));

DROP POLICY IF EXISTS bay_hub_sessions_read ON public.bay_hub_sessions;
CREATE POLICY bay_hub_sessions_read ON public.bay_hub_sessions
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.jwt_tenant_id()
    AND (operator_id = auth.uid() OR private.bay_can_view_tenant(tenant_id))
  );

DROP POLICY IF EXISTS bay_workstations_read ON public.bay_workstations;
CREATE POLICY bay_workstations_read ON public.bay_workstations
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));

DROP POLICY IF EXISTS bay_sessions_read ON public.bay_work_sessions;
CREATE POLICY bay_sessions_read ON public.bay_work_sessions
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.jwt_tenant_id()
    AND (technician_id = auth.uid() OR private.bay_can_view_tenant(tenant_id))
  );

DROP POLICY IF EXISTS bay_schedules_read ON public.bay_maintenance_schedules;
CREATE POLICY bay_schedules_read ON public.bay_maintenance_schedules
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));

DROP POLICY IF EXISTS bay_service_events_read ON public.bay_vehicle_service_events;
CREATE POLICY bay_service_events_read ON public.bay_vehicle_service_events
  FOR SELECT TO authenticated
  USING (private.bay_can_view_tenant(tenant_id));

DO $content_policies$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bay_work_order_notes']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS bay_content_read ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY bay_content_read ON public.%I FOR SELECT TO authenticated '
      'USING (private.bay_can_view_tenant(tenant_id))', t
    );
    EXECUTE format('DROP POLICY IF EXISTS bay_content_insert ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY bay_content_insert ON public.%I FOR INSERT TO authenticated '
      'WITH CHECK (private.bay_can_manage_tenant(tenant_id))', t
    );
    EXECUTE format('DROP POLICY IF EXISTS bay_content_update ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY bay_content_update ON public.%I FOR UPDATE TO authenticated '
      'USING (private.bay_can_manage_tenant(tenant_id)) '
      'WITH CHECK (private.bay_can_manage_tenant(tenant_id))', t
    );
  END LOOP;
END
$content_policies$;

DROP POLICY IF EXISTS bay_checkpoints_read ON public.bay_inspection_checkpoints;
CREATE POLICY bay_checkpoints_read ON public.bay_inspection_checkpoints
  FOR SELECT TO authenticated
  USING (
    private.bay_can_view_tenant(tenant_id)
    OR private.bay_pilot_can_contribute_inspection(inspection_id, tenant_id)
  );
DROP POLICY IF EXISTS bay_checkpoints_insert ON public.bay_inspection_checkpoints;
CREATE POLICY bay_checkpoints_insert ON public.bay_inspection_checkpoints
  FOR INSERT TO authenticated
  WITH CHECK (
    private.bay_can_manage_tenant(tenant_id)
    OR private.bay_pilot_can_contribute_inspection(inspection_id, tenant_id)
  );
DROP POLICY IF EXISTS bay_checkpoints_update ON public.bay_inspection_checkpoints;
CREATE POLICY bay_checkpoints_update ON public.bay_inspection_checkpoints
  FOR UPDATE TO authenticated
  USING (
    private.bay_can_manage_tenant(tenant_id)
    OR private.bay_pilot_can_contribute_inspection(inspection_id, tenant_id)
  )
  WITH CHECK (
    private.bay_can_manage_tenant(tenant_id)
    OR private.bay_pilot_can_contribute_inspection(inspection_id, tenant_id)
  );

DROP POLICY IF EXISTS bay_media_metadata_read ON public.bay_inspection_media;
CREATE POLICY bay_media_metadata_read ON public.bay_inspection_media
  FOR SELECT TO authenticated
  USING (
    private.bay_can_view_tenant(tenant_id)
    OR private.bay_can_contribute_checkpoint(checkpoint_id, tenant_id)
  );
DROP POLICY IF EXISTS bay_media_metadata_insert ON public.bay_inspection_media;
CREATE POLICY bay_media_metadata_insert ON public.bay_inspection_media
  FOR INSERT TO authenticated
  WITH CHECK (private.bay_can_contribute_checkpoint(checkpoint_id, tenant_id));
DROP POLICY IF EXISTS bay_media_metadata_update ON public.bay_inspection_media;
CREATE POLICY bay_media_metadata_update ON public.bay_inspection_media
  FOR UPDATE TO authenticated
  USING (private.bay_can_contribute_checkpoint(checkpoint_id, tenant_id))
  WITH CHECK (private.bay_can_contribute_checkpoint(checkpoint_id, tenant_id));

REVOKE ALL ON TABLE public.bay_tenant_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_staff_authorizations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_hubs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_hub_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_workstations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_work_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_maintenance_schedules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_vehicle_service_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_work_order_notes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_inspection_checkpoints FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bay_inspection_media FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.bay_tenant_settings, public.bay_staff_authorizations,
  public.bay_hubs, public.bay_hub_sessions, public.bay_workstations,
  public.bay_work_sessions, public.bay_maintenance_schedules,
  public.bay_vehicle_service_events TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.bay_work_order_notes,
  public.bay_inspection_checkpoints, public.bay_inspection_media TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.maintenance_work_orders FROM authenticated;
GRANT SELECT ON TABLE public.maintenance_work_orders TO authenticated;
GRANT INSERT (bus_id, issue_description, priority, status, resolved_at)
  ON TABLE public.maintenance_work_orders TO authenticated;
GRANT UPDATE (
  issue_description, priority, status, resolved_at, last_activity_at
) ON TABLE public.maintenance_work_orders TO authenticated;
GRANT USAGE ON SEQUENCE public.bay_ticket_number_seq TO authenticated;

REVOKE DELETE ON TABLE public.bus_inspections FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.bus_inspections TO authenticated;

CREATE OR REPLACE FUNCTION public.bay_begin_hub_session(p_hub_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_hub public.bay_hubs%ROWTYPE;
  v_session public.bay_hub_sessions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT public.orbit_has_capability('BAY', v_tenant)
     OR NOT private.bay_user_has_hub_authorization(auth.uid(), v_tenant, 'HUB_LOGIN') THEN
    RAISE EXCEPTION 'BAY_HUB_AUTHORIZATION_REQUIRED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_hub
  FROM public.bay_hubs h
  WHERE h.tenant_id = v_tenant
    AND h.hub_code = p_hub_code
    AND h.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'BAY_HUB_NOT_FOUND'; END IF;

  UPDATE public.bay_hub_sessions
  SET session_state = 'REPLACED', ended_at = clock_timestamp(),
      end_reason = 'NEW_HUB_LOGIN', updated_at = clock_timestamp()
  WHERE tenant_id = v_tenant
    AND session_state = 'ACTIVE'
    AND (hub_id = v_hub.id OR operator_id = auth.uid());

  INSERT INTO public.bay_hub_sessions(
    tenant_id, hub_id, operator_id, lease_expires_at
  ) VALUES (
    v_tenant, v_hub.id, auth.uid(), clock_timestamp() + interval '8 hours'
  ) RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'hub_session_id', v_session.id,
    'hub_id', v_session.hub_id,
    'operator_id', v_session.operator_id,
    'session_state', v_session.session_state,
    'lease_expires_at', v_session.lease_expires_at
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_end_hub_session(
  p_hub_session_id uuid,
  p_reason text DEFAULT 'LOGOUT'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session public.bay_hub_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_session
  FROM public.bay_hub_sessions
  WHERE id = p_hub_session_id FOR UPDATE;

  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_session.operator_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'BAY_HUB_SESSION_NOT_FOUND' USING ERRCODE = '42501';
  END IF;

  IF v_session.session_state = 'ACTIVE' THEN
    UPDATE public.bay_hub_sessions
    SET session_state = 'ENDED', ended_at = clock_timestamp(),
        end_reason = LEFT(COALESCE(NULLIF(btrim(p_reason), ''), 'LOGOUT'), 120),
        updated_at = clock_timestamp()
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  END IF;

  RETURN jsonb_build_object(
    'hub_session_id', v_session.id,
    'session_state', v_session.session_state,
    'ended_at', v_session.ended_at
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_schedule_maintenance(
  p_hub_session_id uuid,
  p_bus_id uuid,
  p_maintenance_type text,
  p_description text,
  p_scheduled_start_at timestamptz,
  p_scheduled_end_at timestamptz DEFAULT NULL,
  p_due_odometer integer DEFAULT NULL,
  p_down_vehicle_at_start boolean DEFAULT false,
  p_work_order_id uuid DEFAULT NULL,
  p_client_mutation_id uuid DEFAULT uuid_generate_v4()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_session public.bay_hub_sessions%ROWTYPE;
  v_auth_time timestamptz;
  v_schedule public.bay_maintenance_schedules%ROWTYPE;
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
    auth.uid(), v_tenant, 'SCHEDULE_MAINTENANCE'
  ) THEN
    RAISE EXCEPTION 'BAY_SCHEDULE_AUTHORIZATION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  v_auth_time := private.bay_fresh_credential_time(300);

  IF NOT EXISTS (
    SELECT 1 FROM public.buses b WHERE b.id = p_bus_id AND b.tenant_id = v_tenant
  ) THEN RAISE EXCEPTION 'BAY_BUS_NOT_FOUND'; END IF;
  IF p_work_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.maintenance_work_orders wo
    WHERE wo.id = p_work_order_id AND wo.tenant_id = v_tenant AND wo.bus_id = p_bus_id
  ) THEN RAISE EXCEPTION 'BAY_WORK_ORDER_LINK_INVALID'; END IF;

  INSERT INTO public.bay_maintenance_schedules(
    tenant_id, bus_id, work_order_id, maintenance_type, description,
    scheduled_start_at, scheduled_end_at, due_odometer,
    down_vehicle_at_start, created_by, hub_session_id,
    credential_verified_at, auth_session_id, client_mutation_id
  ) VALUES (
    v_tenant, p_bus_id, p_work_order_id, btrim(p_maintenance_type),
    btrim(p_description), p_scheduled_start_at, p_scheduled_end_at,
    p_due_odometer, p_down_vehicle_at_start, auth.uid(), v_session.id,
    v_auth_time, auth.jwt() ->> 'session_id', p_client_mutation_id
  )
  ON CONFLICT (tenant_id, client_mutation_id) DO UPDATE
    SET client_mutation_id = EXCLUDED.client_mutation_id
  RETURNING * INTO v_schedule;

  UPDATE public.bay_hub_sessions
  SET last_seen_at = clock_timestamp(), updated_at = clock_timestamp()
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'schedule_id', v_schedule.id,
    'bus_id', v_schedule.bus_id,
    'scheduled_start_at', v_schedule.scheduled_start_at,
    'scheduled_end_at', v_schedule.scheduled_end_at,
    'down_vehicle_at_start', v_schedule.down_vehicle_at_start,
    'schedule_status', v_schedule.schedule_status,
    'credential_verified_at', v_schedule.credential_verified_at
  );
END
$function$;

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

CREATE OR REPLACE FUNCTION public.bay_touch_work_session(
  p_session_id uuid,
  p_current_work_order_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session public.bay_work_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_session FROM public.bay_work_sessions
  WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_session.technician_id IS DISTINCT FROM auth.uid()
     OR v_session.session_state NOT IN ('ACTIVE', 'DISCONNECTED') THEN
    RAISE EXCEPTION 'BAY_ACTIVE_SESSION_REQUIRED' USING ERRCODE = '42501';
  END IF;

  IF v_session.lease_expires_at <= clock_timestamp() THEN
    UPDATE public.bay_work_sessions
    SET session_state = 'EXPIRED', ended_at = clock_timestamp(),
        end_reason = 'LEASE_EXPIRED', updated_at = clock_timestamp()
    WHERE id = v_session.id;
    RAISE EXCEPTION 'BAY_SESSION_EXPIRED' USING ERRCODE = '42501';
  END IF;

  IF p_current_work_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.maintenance_work_orders wo
    WHERE wo.id = p_current_work_order_id
      AND wo.tenant_id = v_session.tenant_id
      AND wo.claimed_by_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'BAY_WORK_ORDER_NOT_CLAIMED_BY_TECHNICIAN' USING ERRCODE = '42501';
  END IF;

  UPDATE public.bay_work_sessions
  SET session_state = 'ACTIVE', last_seen_at = clock_timestamp(),
      current_work_order_id = COALESCE(p_current_work_order_id, current_work_order_id),
      updated_at = clock_timestamp()
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'session_state', v_session.session_state,
    'current_work_order_id', v_session.current_work_order_id,
    'last_seen_at', v_session.last_seen_at,
    'lease_expires_at', v_session.lease_expires_at
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_end_work_session(
  p_session_id uuid,
  p_reason text DEFAULT 'LOGOUT'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session public.bay_work_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_session FROM public.bay_work_sessions
  WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_session.technician_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'BAY_SESSION_NOT_FOUND' USING ERRCODE = '42501';
  END IF;

  IF v_session.session_state IN ('ACTIVE', 'DISCONNECTED') THEN
    UPDATE public.bay_work_sessions
    SET session_state = 'ENDED', ended_at = clock_timestamp(),
        end_reason = LEFT(COALESCE(NULLIF(btrim(p_reason), ''), 'LOGOUT'), 120),
        updated_at = clock_timestamp()
    WHERE id = v_session.id
    RETURNING * INTO v_session;
  END IF;

  UPDATE public.trusted_hardware
  SET assigned_staff_id = NULL, last_sync_at = clock_timestamp()
  WHERE id = v_session.tablet_hardware_id AND assigned_staff_id = auth.uid();

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'session_state', v_session.session_state,
    'current_work_order_id', v_session.current_work_order_id,
    'ended_at', v_session.ended_at
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_claim_work_order(
  p_work_order_id uuid,
  p_session_id uuid,
  p_expected_version bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session public.bay_work_sessions%ROWTYPE;
  v_order public.maintenance_work_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_session FROM public.bay_work_sessions
  WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_session.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_session.technician_id IS DISTINCT FROM auth.uid()
     OR v_session.session_state NOT IN ('ACTIVE', 'DISCONNECTED')
     OR v_session.lease_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'BAY_ACTIVE_SESSION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT private.bay_can_manage_tenant(v_session.tenant_id) THEN
    RAISE EXCEPTION 'BAY_MANAGE_REQUIRED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.maintenance_work_orders
  WHERE id = p_work_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.tenant_id IS DISTINCT FROM v_session.tenant_id THEN
    RAISE EXCEPTION 'BAY_WORK_ORDER_NOT_FOUND';
  END IF;
  IF p_expected_version IS NOT NULL AND v_order.lock_version <> p_expected_version THEN
    RAISE EXCEPTION 'BAY_VERSION_CONFLICT' USING ERRCODE = '40001';
  END IF;
  IF v_order.status = 'Resolved' THEN
    RAISE EXCEPTION 'BAY_WORK_ORDER_RESOLVED' USING ERRCODE = '55000';
  END IF;
  IF v_order.assigned_crew_id IS NOT NULL AND v_order.assigned_crew_id <> auth.uid() THEN
    RAISE EXCEPTION 'BAY_TICKET_ASSIGNED_TO_ANOTHER' USING ERRCODE = '42501';
  END IF;
  IF v_order.claimed_by_id IS NOT NULL AND v_order.claimed_by_id <> auth.uid() THEN
    RAISE EXCEPTION 'BAY_TICKET_ALREADY_CLAIMED' USING ERRCODE = '55P03';
  END IF;

  UPDATE public.maintenance_work_orders
  SET claimed_by_id = auth.uid(), claimed_at = COALESCE(claimed_at, clock_timestamp()),
      claim_session_id = v_session.id,
      assigned_crew_id = COALESCE(assigned_crew_id, auth.uid()),
      status = CASE WHEN status = 'Open' THEN 'In_Progress' ELSE status END,
      last_activity_at = clock_timestamp()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  UPDATE public.bay_work_sessions
  SET current_work_order_id = v_order.id, session_state = 'ACTIVE',
      last_seen_at = clock_timestamp(), updated_at = clock_timestamp()
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'work_order_id', v_order.id,
    'ticket_number', v_order.ticket_number,
    'claimed_by_id', v_order.claimed_by_id,
    'assigned_crew_id', v_order.assigned_crew_id,
    'status', v_order.status,
    'lock_version', v_order.lock_version,
    'session_id', v_session.id
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_assign_work_order(
  p_work_order_id uuid,
  p_technician_id uuid,
  p_expected_version bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := public.jwt_tenant_id();
  v_order public.maintenance_work_orders%ROWTYPE;
BEGIN
  IF NOT private.bay_can_manage_tenant(v_tenant) THEN
    RAISE EXCEPTION 'BAY_MANAGE_REQUIRED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.maintenance_work_orders
  WHERE id = p_work_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'BAY_WORK_ORDER_NOT_FOUND';
  END IF;
  IF p_expected_version IS NOT NULL AND v_order.lock_version <> p_expected_version THEN
    RAISE EXCEPTION 'BAY_VERSION_CONFLICT' USING ERRCODE = '40001';
  END IF;
  IF NOT private.bay_user_is_manager(p_technician_id, v_tenant) THEN
    RAISE EXCEPTION 'BAY_TECHNICIAN_NOT_AUTHORIZED' USING ERRCODE = '42501';
  END IF;
  IF v_order.claimed_by_id IS NOT NULL AND v_order.claimed_by_id <> p_technician_id THEN
    RAISE EXCEPTION 'BAY_TICKET_CURRENTLY_CLAIMED' USING ERRCODE = '55P03';
  END IF;

  UPDATE public.maintenance_work_orders
  SET assigned_crew_id = p_technician_id, last_activity_at = clock_timestamp()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  RETURN jsonb_build_object(
    'work_order_id', v_order.id,
    'ticket_number', v_order.ticket_number,
    'assigned_crew_id', v_order.assigned_crew_id,
    'claimed_by_id', v_order.claimed_by_id,
    'status', v_order.status,
    'lock_version', v_order.lock_version
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.bay_release_work_order(
  p_work_order_id uuid,
  p_expected_version bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_order public.maintenance_work_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.maintenance_work_orders
  WHERE id = p_work_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.tenant_id IS DISTINCT FROM public.jwt_tenant_id()
     OR v_order.claimed_by_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'BAY_CLAIM_OWNER_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_expected_version IS NOT NULL AND v_order.lock_version <> p_expected_version THEN
    RAISE EXCEPTION 'BAY_VERSION_CONFLICT' USING ERRCODE = '40001';
  END IF;

  UPDATE public.maintenance_work_orders
  SET claimed_by_id = NULL, claimed_at = NULL, claim_session_id = NULL,
      status = CASE WHEN status = 'In_Progress' THEN 'Open' ELSE status END,
      last_activity_at = clock_timestamp()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  UPDATE public.bay_work_sessions
  SET current_work_order_id = NULL, updated_at = clock_timestamp()
  WHERE technician_id = auth.uid()
    AND current_work_order_id = v_order.id
    AND session_state IN ('ACTIVE', 'DISCONNECTED');

  RETURN jsonb_build_object(
    'work_order_id', v_order.id,
    'ticket_number', v_order.ticket_number,
    'claimed_by_id', v_order.claimed_by_id,
    'status', v_order.status,
    'lock_version', v_order.lock_version
  );
END
$function$;

REVOKE ALL ON FUNCTION public.bay_begin_hub_session(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_end_hub_session(uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_schedule_maintenance(
  uuid, uuid, text, text, timestamptz, timestamptz, integer, boolean, uuid, uuid
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_down_vehicle(uuid, uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_return_vehicle_to_service(uuid, uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_begin_work_session(text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_replace_tablet(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_touch_work_session(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_end_work_session(uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_claim_work_order(uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_assign_work_order(uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bay_release_work_order(uuid, bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.bay_begin_hub_session(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_end_hub_session(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_schedule_maintenance(
  uuid, uuid, text, text, timestamptz, timestamptz, integer, boolean, uuid, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_down_vehicle(uuid, uuid, text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_return_vehicle_to_service(uuid, uuid, text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_begin_work_session(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_replace_tablet(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_touch_work_session(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_end_work_session(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_claim_work_order(uuid, uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_assign_work_order(uuid, uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bay_release_work_order(uuid, bigint) TO authenticated;

INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'bay-inspection-media',
  'bay-inspection-media',
  false,
  20971520,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS bay_inspection_media_read ON storage.objects;
CREATE POLICY bay_inspection_media_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'bay-inspection-media'
    AND (storage.foldername(name))[1] = public.jwt_tenant_id()::text
    AND (
      private.bay_can_view_tenant(public.jwt_tenant_id())
      OR CASE
        WHEN (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        THEN private.bay_can_contribute_checkpoint(
          ((storage.foldername(name))[2])::uuid,
          public.jwt_tenant_id()
        )
        ELSE false
      END
    )
  );

DROP POLICY IF EXISTS bay_inspection_media_insert ON storage.objects;
CREATE POLICY bay_inspection_media_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'bay-inspection-media'
    AND (storage.foldername(name))[1] = public.jwt_tenant_id()::text
    AND CASE
      WHEN (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN private.bay_can_contribute_checkpoint(
        ((storage.foldername(name))[2])::uuid,
        public.jwt_tenant_id()
      )
      ELSE false
    END
  );

DO $realtime$
DECLARE
  t text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY[
      'maintenance_work_orders',
      'bus_inspections',
      'bay_hub_sessions',
      'bay_work_sessions',
      'bay_maintenance_schedules',
      'bay_vehicle_service_events',
      'bay_work_order_notes',
      'bay_inspection_checkpoints',
      'bay_inspection_media'
    ]
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = t
      ) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END
$realtime$;

COMMENT ON TABLE public.bay_work_sessions IS
  'Temporary dynamic binding of one technician, cart workstation, and replaceable Bay tablet. Auth tokens are never copied between devices.';
COMMENT ON COLUMN public.bay_inspection_checkpoints.description IS
  'Technician description displayed with optional bay_inspection_media attachments for this exact checkpoint.';
COMMENT ON TABLE public.bay_inspection_media IS
  'Immutable photo evidence metadata. Binary objects live in the private bay-inspection-media Storage bucket.';
COMMENT ON TABLE public.bay_hubs IS
  'Registered Bay authority clients. Scheduling and vehicle service-state changes are accepted only through an active hub session.';
COMMENT ON TABLE public.bay_vehicle_service_events IS
  'Immutable domain record of vehicle downing and return-to-service acknowledgements, including fresh credential and supervisor-override evidence.';
COMMENT ON COLUMN public.bus_inspections.sync_received_at IS
  'Server receipt time used by the Bay Hub catalog for Pilot pre-, mid-, and post-trip inspection synchronization.';

COMMIT;
