-- Orbit Bay deterministic simulator seed
-- DEV/STAGING ONLY. Run only through -IncludeDevSeed after migrations 14-17.

BEGIN;

DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.districts
    WHERE id = '81d25f6a-c459-5b6b-bc83-8e29e5847d50'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.contractors
    WHERE id = 'edcee794-1b2f-5632-b5d6-8969a6696276'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.staff_profiles
    WHERE id IN (
      '10000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000010'
    )
      AND tenant_id = '81d25f6a-c459-5b6b-bc83-8e29e5847d50'
    GROUP BY tenant_id
    HAVING count(*) = 2
  ) OR NOT EXISTS (
    SELECT 1 FROM public.buses
    WHERE id = '9684b297-8bc2-5088-8f5a-3579bef64c59'
      AND tenant_id = '81d25f6a-c459-5b6b-bc83-8e29e5847d50'
  ) THEN
    RAISE EXCEPTION 'BAY_DEV_SEED_PREFLIGHT_FAILED';
  END IF;
END
$preflight$;

INSERT INTO public.bay_tenant_settings(
  id, tenant_id, operation_model, maintenance_contractor_id,
  pairing_lease_hours, max_photos_per_checkpoint
) VALUES (
  'ba900000-0000-4000-8000-000000000000',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  'OUTSOURCED',
  'edcee794-1b2f-5632-b5d6-8969a6696276',
  12,
  8
)
ON CONFLICT (tenant_id) DO UPDATE SET
  operation_model = EXCLUDED.operation_model,
  maintenance_contractor_id = EXCLUDED.maintenance_contractor_id,
  pairing_lease_hours = EXCLUDED.pairing_lease_hours,
  max_photos_per_checkpoint = EXCLUDED.max_photos_per_checkpoint;

INSERT INTO public.trusted_hardware(
  id, tenant_id, device_fingerprint, device_type, is_active
) VALUES
  (
    'b9000000-0000-4000-8000-000000000001',
    '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
    'orbit-bay-sim-hub-01', 'Bay_Hub', true
  ),
  (
    'b9000000-0000-4000-8000-000000000002',
    '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
    'orbit-bay-sim-workstation-01', 'Bay_Workstation', true
  ),
  (
    'b9000000-0000-4000-8000-000000000003',
    '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
    'orbit-bay-sim-tablet-01', 'Bay_Tablet', true
  ),
  (
    'b9000000-0000-4000-8000-000000000004',
    '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
    'orbit-bay-sim-tablet-02', 'Bay_Tablet', true
  )
ON CONFLICT (id) DO UPDATE SET
  tenant_id = EXCLUDED.tenant_id,
  device_fingerprint = EXCLUDED.device_fingerprint,
  device_type = EXCLUDED.device_type,
  is_active = true;

INSERT INTO public.bay_hubs(
  id, tenant_id, hardware_id, hub_code, display_name, bay_location, is_active
) VALUES (
  'ba900000-0000-4000-8000-000000000001',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  'b9000000-0000-4000-8000-000000000001',
  'HUB-01', 'Orbit Bay Main Hub', 'Supervisor Office', true
)
ON CONFLICT (id) DO UPDATE SET
  hardware_id = EXCLUDED.hardware_id,
  hub_code = EXCLUDED.hub_code,
  display_name = EXCLUDED.display_name,
  bay_location = EXCLUDED.bay_location,
  is_active = true;

INSERT INTO public.bay_workstations(
  id, tenant_id, hardware_id, station_code, display_name, bay_location, is_active
) VALUES (
  'ba900000-0000-4000-8000-000000000002',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  'b9000000-0000-4000-8000-000000000002',
  'WS-01', 'Orbit Bay Cart 01', 'Service Lane 1', true
)
ON CONFLICT (id) DO UPDATE SET
  hardware_id = EXCLUDED.hardware_id,
  station_code = EXCLUDED.station_code,
  display_name = EXCLUDED.display_name,
  bay_location = EXCLUDED.bay_location,
  is_active = true;

INSERT INTO public.bay_staff_authorizations(
  id, tenant_id, staff_id, may_use_hub, may_schedule_maintenance,
  may_change_service_status, is_supervisor, granted_by
) VALUES (
  'ba900000-0000-4000-8000-000000000003',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  '10000000-0000-4000-8000-000000000010',
  true, true, true, true,
  '10000000-0000-4000-8000-000000000010'
)
ON CONFLICT (tenant_id, staff_id) DO UPDATE SET
  may_use_hub = true,
  may_schedule_maintenance = true,
  may_change_service_status = true,
  is_supervisor = true,
  valid_until = NULL,
  revoked_at = NULL,
  revoked_by = NULL;

INSERT INTO public.maintenance_work_orders(
  id, tenant_id, bus_id, reported_by_id, issue_description, priority, status
) VALUES (
  'ba900000-0000-4000-8000-000000000010',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  '9684b297-8bc2-5088-8f5a-3579bef64c59',
  '10000000-0000-4000-8000-000000000010',
  'Simulator ticket: inspect right-front tire wear and document findings.',
  'Standard', 'Open'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.bus_inspections(
  id, tenant_id, bus_id, inspector_id, inspection_type, inspection_status,
  mileage, notes, source_system, submitted_by, submitted_at
) VALUES (
  'ba900000-0000-4000-8000-000000000020',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  '9684b297-8bc2-5088-8f5a-3579bef64c59',
  '10000000-0000-4000-8000-000000000001',
  'Pre_Trip', 'Passed', 45210,
  'Simulator pre-trip received by the Bay Hub catalog.',
  'PILOT_APP',
  '10000000-0000-4000-8000-000000000001',
  clock_timestamp()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.bay_inspection_checkpoints(
  id, tenant_id, inspection_id, item_code, item_label, component_area,
  prompt, description, result, sequence_number, completed_by, completed_at,
  client_mutation_id
) VALUES (
  'ba900000-0000-4000-8000-000000000021',
  '81d25f6a-c459-5b6b-bc83-8e29e5847d50',
  'ba900000-0000-4000-8000-000000000020',
  'EXTERIOR_RIGHT_FRONT_TIRE', 'Right-front tire', 'Exterior / Wheels',
  'Check tread, sidewall, inflation appearance, and visible damage.',
  'No cuts or bulges observed; tread appears serviceable.',
  'PASS', 10,
  '10000000-0000-4000-8000-000000000001',
  clock_timestamp(),
  'ba900000-0000-4000-8000-000000000022'
)
ON CONFLICT (id) DO NOTHING;

COMMIT;
