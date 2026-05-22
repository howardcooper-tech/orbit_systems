-- ORBIT PHASE 1 — 12: Performance indexes

BEGIN;

CREATE INDEX idx_students_sis ON public.students (sis_student_id);
CREATE INDEX idx_students_school ON public.students (school_id);
CREATE INDEX idx_students_emergency_flare ON public.students (id, school_id) WHERE missing_status <> 'NONE';
CREATE INDEX idx_sis_enrollment_school ON public.student_sis_enrollment (school_id, enrollment_status);

CREATE INDEX idx_telemetry_bus_recorded ON public.bus_telemetry_logs (bus_id, recorded_at DESC);
CREATE INDEX idx_buses_district ON public.buses (district_id);
CREATE INDEX idx_buses_active_motion ON public.buses (id, bus_number) WHERE status = 'Active' AND motion_status = 'Moving';

CREATE INDEX idx_manifest_lookup ON public.trip_manifest (trip_id, student_id, expected_status);
CREATE INDEX idx_trip_handshakes_bus ON public.bus_trip_handshakes (bus_id, status);

CREATE INDEX idx_audit_record_search ON public.audit_logs (record_id, created_at DESC);
CREATE INDEX idx_audit_user_search ON public.audit_logs (user_id, action_type);
CREATE INDEX idx_audit_new_data_gin ON public.audit_logs USING GIN (new_data);

CREATE INDEX idx_scan_student_created ON public.student_scan_events (student_id, created_at DESC);
CREATE INDEX idx_scan_bus_created ON public.student_scan_events (bus_id, created_at DESC);

CREATE INDEX idx_flares_district_created ON public.emergency_flares (district_id, created_at DESC);
CREATE INDEX idx_outbound_recipient ON public.outbound_alerts (recipient_id, created_at DESC);

CREATE INDEX idx_trip_chaperones_trip ON public.trip_chaperone_groups (trip_id);
CREATE INDEX idx_trip_checkouts_trip ON public.field_trip_checkouts (trip_id);
CREATE INDEX idx_halo_manifest_session ON public.halo_manifest_snapshots (halo_session_id);
CREATE INDEX idx_trusted_hardware_bus ON public.trusted_hardware (assigned_bus_id);

COMMIT;
