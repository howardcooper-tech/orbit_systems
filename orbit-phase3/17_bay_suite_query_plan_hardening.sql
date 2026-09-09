-- Orbit Bay query-plan hardening
-- Consolidates overlapping inspection policies, caches auth lookups per
-- statement, and covers foreign-key lookup paths used by deletes and joins.

DROP POLICY IF EXISTS bay_pilot_inspections_read ON public.bus_inspections;
DROP POLICY IF EXISTS bay_pilot_inspections_insert ON public.bus_inspections;
DROP POLICY IF EXISTS bay_pilot_inspections_update ON public.bus_inspections;

DROP POLICY IF EXISTS bay_inspections_read ON public.bus_inspections;
CREATE POLICY bay_inspections_read ON public.bus_inspections
  FOR SELECT TO authenticated
  USING (
    private.bay_can_view_tenant(tenant_id)
    OR (
      tenant_id = (SELECT public.jwt_tenant_id())
      AND inspector_id = (SELECT auth.uid())
      AND (SELECT public.get_my_role()) IN ('Pilot', 'Halo')
      AND EXISTS (
        SELECT 1 FROM public.buses b
        WHERE b.id = bus_id
          AND b.assigned_pilot_id = (SELECT auth.uid())
      )
    )
  );

DROP POLICY IF EXISTS bay_inspections_insert ON public.bus_inspections;
CREATE POLICY bay_inspections_insert ON public.bus_inspections
  FOR INSERT TO authenticated
  WITH CHECK (
    private.bay_can_manage_tenant(tenant_id)
    OR (
      tenant_id = (SELECT public.jwt_tenant_id())
      AND inspector_id = (SELECT auth.uid())
      AND submitted_by = (SELECT auth.uid())
      AND source_system = 'PILOT_APP'
      AND (SELECT public.get_my_role()) IN ('Pilot', 'Halo')
      AND EXISTS (
        SELECT 1 FROM public.buses b
        WHERE b.id = bus_id
          AND b.tenant_id = tenant_id
          AND b.assigned_pilot_id = (SELECT auth.uid())
      )
    )
  );

DROP POLICY IF EXISTS bay_inspections_update ON public.bus_inspections;
CREATE POLICY bay_inspections_update ON public.bus_inspections
  FOR UPDATE TO authenticated
  USING (
    private.bay_can_manage_tenant(tenant_id)
    OR (
      tenant_id = (SELECT public.jwt_tenant_id())
      AND inspector_id = (SELECT auth.uid())
      AND submitted_by = (SELECT auth.uid())
      AND source_system = 'PILOT_APP'
      AND inspection_status = 'In_Progress'
    )
  )
  WITH CHECK (
    private.bay_can_manage_tenant(tenant_id)
    OR (
      tenant_id = (SELECT public.jwt_tenant_id())
      AND inspector_id = (SELECT auth.uid())
      AND submitted_by = (SELECT auth.uid())
      AND source_system = 'PILOT_APP'
    )
  );

DROP POLICY IF EXISTS bay_staff_authorizations_read ON public.bay_staff_authorizations;
CREATE POLICY bay_staff_authorizations_read ON public.bay_staff_authorizations
  FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT public.jwt_tenant_id())
    AND (
      staff_id = (SELECT auth.uid())
      OR private.bay_can_view_tenant(tenant_id)
    )
  );

DROP POLICY IF EXISTS bay_hub_sessions_read ON public.bay_hub_sessions;
CREATE POLICY bay_hub_sessions_read ON public.bay_hub_sessions
  FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT public.jwt_tenant_id())
    AND (
      operator_id = (SELECT auth.uid())
      OR private.bay_can_view_tenant(tenant_id)
    )
  );

DROP POLICY IF EXISTS bay_sessions_read ON public.bay_work_sessions;
CREATE POLICY bay_sessions_read ON public.bay_work_sessions
  FOR SELECT TO authenticated
  USING (
    tenant_id = (SELECT public.jwt_tenant_id())
    AND (
      technician_id = (SELECT auth.uid())
      OR private.bay_can_view_tenant(tenant_id)
    )
  );

CREATE INDEX IF NOT EXISTS bay_checkpoints_completed_by_idx
  ON public.bay_inspection_checkpoints(completed_by);
CREATE INDEX IF NOT EXISTS bay_checkpoints_source_session_idx
  ON public.bay_inspection_checkpoints(source_session_id);
CREATE INDEX IF NOT EXISTS bay_checkpoints_work_order_fk_idx
  ON public.bay_inspection_checkpoints(work_order_id);

CREATE INDEX IF NOT EXISTS bay_media_captured_by_idx
  ON public.bay_inspection_media(captured_by);
CREATE INDEX IF NOT EXISTS bay_media_captured_device_idx
  ON public.bay_inspection_media(captured_device_id);
CREATE INDEX IF NOT EXISTS bay_media_checkpoint_fk_idx
  ON public.bay_inspection_media(checkpoint_id);
CREATE INDEX IF NOT EXISTS bay_media_voided_by_idx
  ON public.bay_inspection_media(voided_by);

CREATE INDEX IF NOT EXISTS bay_schedule_bus_fk_idx
  ON public.bay_maintenance_schedules(bus_id);
CREATE INDEX IF NOT EXISTS bay_schedule_created_by_idx
  ON public.bay_maintenance_schedules(created_by);
CREATE INDEX IF NOT EXISTS bay_schedule_hub_session_idx
  ON public.bay_maintenance_schedules(hub_session_id);
CREATE INDEX IF NOT EXISTS bay_schedule_work_order_idx
  ON public.bay_maintenance_schedules(work_order_id);

CREATE INDEX IF NOT EXISTS bay_staff_authorizations_granted_by_idx
  ON public.bay_staff_authorizations(granted_by);
CREATE INDEX IF NOT EXISTS bay_staff_authorizations_revoked_by_idx
  ON public.bay_staff_authorizations(revoked_by);
CREATE INDEX IF NOT EXISTS bay_staff_authorizations_staff_fk_idx
  ON public.bay_staff_authorizations(staff_id);
CREATE INDEX IF NOT EXISTS bay_settings_maintenance_contractor_idx
  ON public.bay_tenant_settings(maintenance_contractor_id);

CREATE INDEX IF NOT EXISTS bay_service_events_authorized_by_idx
  ON public.bay_vehicle_service_events(authorized_by);
CREATE INDEX IF NOT EXISTS bay_service_events_bus_fk_idx
  ON public.bay_vehicle_service_events(bus_id);
CREATE INDEX IF NOT EXISTS bay_service_events_hub_idx
  ON public.bay_vehicle_service_events(hub_id);
CREATE INDEX IF NOT EXISTS bay_service_events_hub_session_idx
  ON public.bay_vehicle_service_events(hub_session_id);
CREATE INDEX IF NOT EXISTS bay_service_events_requested_by_idx
  ON public.bay_vehicle_service_events(requested_by);

CREATE INDEX IF NOT EXISTS bay_notes_created_by_idx
  ON public.bay_work_order_notes(created_by);
CREATE INDEX IF NOT EXISTS bay_notes_last_edited_by_idx
  ON public.bay_work_order_notes(last_edited_by);
CREATE INDEX IF NOT EXISTS bay_notes_source_session_idx
  ON public.bay_work_order_notes(source_session_id);
CREATE INDEX IF NOT EXISTS bay_notes_work_order_fk_idx
  ON public.bay_work_order_notes(work_order_id);

CREATE INDEX IF NOT EXISTS bay_work_sessions_current_order_idx
  ON public.bay_work_sessions(current_work_order_id);
CREATE INDEX IF NOT EXISTS bay_work_sessions_previous_session_idx
  ON public.bay_work_sessions(previous_session_id);

CREATE INDEX IF NOT EXISTS bus_inspections_bus_fk_idx
  ON public.bus_inspections(bus_id);
CREATE INDEX IF NOT EXISTS bus_inspections_inspector_idx
  ON public.bus_inspections(inspector_id);
CREATE INDEX IF NOT EXISTS bus_inspections_source_device_idx
  ON public.bus_inspections(source_device_id);
CREATE INDEX IF NOT EXISTS bus_inspections_submitted_by_idx
  ON public.bus_inspections(submitted_by);
CREATE INDEX IF NOT EXISTS bus_inspections_trip_idx
  ON public.bus_inspections(trip_id);
CREATE INDEX IF NOT EXISTS bus_inspections_work_order_fk_idx
  ON public.bus_inspections(work_order_id);

CREATE INDEX IF NOT EXISTS maintenance_work_orders_assigned_crew_idx
  ON public.maintenance_work_orders(assigned_crew_id);
CREATE INDEX IF NOT EXISTS maintenance_work_orders_bus_fk_idx
  ON public.maintenance_work_orders(bus_id);
CREATE INDEX IF NOT EXISTS maintenance_work_orders_claim_session_idx
  ON public.maintenance_work_orders(claim_session_id);
CREATE INDEX IF NOT EXISTS maintenance_work_orders_claimed_by_idx
  ON public.maintenance_work_orders(claimed_by_id);
CREATE INDEX IF NOT EXISTS maintenance_work_orders_reported_by_idx
  ON public.maintenance_work_orders(reported_by_id);
