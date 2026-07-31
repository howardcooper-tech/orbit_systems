-- Phase 3 — Duval Wall: staff policies use get_my_role(); parents use auth.uid()

BEGIN;

-- ---------- Parents ----------
CREATE POLICY parent_view_self ON public.parents FOR SELECT USING (id = auth.uid());
CREATE POLICY parent_update_self ON public.parents FOR UPDATE USING (id = auth.uid());

CREATE POLICY parent_view_guardian_profile ON public.guardian_profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY parent_update_guardian_profile ON public.guardian_profiles FOR UPDATE USING (id = auth.uid());

CREATE POLICY parent_view_own_students ON public.students FOR SELECT
USING (id IN (SELECT student_id FROM public.student_guardians WHERE parent_id = auth.uid()));

CREATE POLICY parent_view_sis_enrollment ON public.student_sis_enrollment FOR SELECT
USING (sis_student_id IN (
    SELECT s.sis_student_id FROM public.students s
    JOIN public.student_guardians sg ON sg.student_id = s.id
    WHERE sg.parent_id = auth.uid()
));

CREATE POLICY parent_view_device_auth ON public.student_device_authorizations FOR ALL
USING (parent_id = auth.uid()) WITH CHECK (parent_id = auth.uid());

CREATE POLICY parent_view_own_waivers ON public.custody_waiver_logs FOR SELECT
USING (guardian_id = auth.uid());
CREATE POLICY parent_insert_waivers ON public.custody_waiver_logs FOR INSERT
WITH CHECK (guardian_id = auth.uid());

-- ---------- Staff (self) ----------
CREATE POLICY staff_view_self ON public.staff_profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY staff_update_self ON public.staff_profiles FOR UPDATE USING (id = auth.uid());

-- ---------- Command / Central (district scope) ----------
CREATE POLICY command_view_district_students ON public.students FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent', 'Principal')
    AND school_id IN (SELECT id FROM public.schools WHERE district_id = public.get_my_district())
);

CREATE POLICY command_view_sis_enrollment ON public.student_sis_enrollment FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent', 'Principal')
    AND school_id IN (SELECT id FROM public.schools WHERE district_id = public.get_my_district())
);

CREATE POLICY command_view_district_buses ON public.buses FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent', 'Crew')
    AND district_id = public.get_my_district()
);

CREATE POLICY command_view_district_trips ON public.trips FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent')
    AND district_id = public.get_my_district()
);

CREATE POLICY command_view_district_telemetry ON public.bus_telemetry_logs FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent')
    AND bus_id IN (SELECT id FROM public.buses WHERE district_id = public.get_my_district())
);

CREATE POLICY command_manage_dispatch_logs ON public.incident_dispatch_logs FOR ALL
USING (public.get_my_role() IN ('Command', 'Central'))
WITH CHECK (public.get_my_role() IN ('Command', 'Central'));

-- ---------- Pilot ----------
CREATE POLICY pilot_view_fleet ON public.buses FOR SELECT
USING (
    public.get_my_role() IN ('Pilot', 'Halo')
    AND (
        assigned_pilot_id = auth.uid()
        OR contractor_id = public.get_my_contractor()
    )
);

CREATE POLICY pilot_insert_telemetry ON public.bus_telemetry_logs FOR INSERT
WITH CHECK (
    public.get_my_role() IN ('Pilot', 'Halo')
    AND bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
);

CREATE POLICY pilot_view_trips ON public.trips FOR SELECT
USING (
    public.get_my_role() IN ('Pilot', 'Halo')
    AND id IN (
        SELECT trip_id FROM public.bus_trip_handshakes
        WHERE bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
    )
);

CREATE POLICY pilot_manage_scans ON public.student_scan_events FOR INSERT
WITH CHECK (public.get_my_role() IN ('Pilot', 'Halo', 'Satellite', 'Staff_Teacher'));

-- ---------- Bay / Crew ----------
CREATE POLICY crew_manage_inspections ON public.bus_inspections FOR ALL
USING (public.get_my_role() IN ('Crew', 'Command', 'Central'))
WITH CHECK (public.get_my_role() IN ('Crew', 'Command', 'Central'));

CREATE POLICY crew_view_work_orders ON public.maintenance_work_orders FOR SELECT
USING (
    public.get_my_role() IN ('Crew', 'Command', 'Central')
    OR bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
);

-- ---------- Mesh / Flares ----------
CREATE POLICY staff_view_waypoints ON public.route_waypoints FOR SELECT
USING (trip_id IN (SELECT id FROM public.trips WHERE district_id = public.get_my_district()));

CREATE POLICY ops_manage_active_mesh ON public.trip_active_mesh FOR ALL
USING (public.get_my_role() IN ('Pilot', 'Command', 'Central', 'Halo'))
WITH CHECK (public.get_my_role() IN ('Pilot', 'Command', 'Central', 'Halo'));

CREATE POLICY flare_visibility ON public.emergency_flares FOR SELECT
USING (
    public.get_my_role() IN ('Command', 'Central', 'Superintendent')
    OR bus_id IN (SELECT id FROM public.buses WHERE assigned_pilot_id = auth.uid())
    OR student_id IN (SELECT student_id FROM public.student_guardians WHERE parent_id = auth.uid())
);

-- ---------- Comms ----------
CREATE POLICY msg_visibility ON public.comms_messages FOR SELECT
USING (sender_id = auth.uid() OR recipient_id = auth.uid());

-- ---------- Halo (satellites) ----------
CREATE POLICY satellite_view_huddle ON public.halo_manifest_snapshots FOR SELECT
USING (
    public.get_my_role() IN ('Satellite', 'Lead_Satellite', 'Staff_Teacher', 'Teacher', 'Command', 'Central')
    AND student_id IN (
        SELECT id FROM public.students
        WHERE school_id IN (SELECT id FROM public.schools WHERE district_id = public.get_my_district())
    )
);

CREATE POLICY satellite_verify_huddle ON public.halo_manifest_snapshots FOR UPDATE
USING (public.get_my_role() IN ('Satellite', 'Lead_Satellite', 'Staff_Teacher', 'Teacher'))
WITH CHECK (public.get_my_role() IN ('Satellite', 'Lead_Satellite', 'Staff_Teacher', 'Teacher'));

-- ---------- Alerts ----------
CREATE POLICY alert_view_personal ON public.outbound_alerts FOR SELECT
USING (recipient_id = auth.uid());

CREATE POLICY alert_view_district ON public.outbound_alerts FOR SELECT
USING (public.get_my_role() IN ('Superintendent', 'Command', 'Central'));

-- ---------- Manifest (staff district) ----------
CREATE POLICY staff_view_manifest ON public.trip_manifest FOR SELECT
USING (
    trip_id IN (SELECT id FROM public.trips WHERE district_id = public.get_my_district())
);

-- Service role / backend: use Edge Functions with service key; bypasses RLS by design.

COMMIT;
