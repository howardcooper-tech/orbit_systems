-- =============================================================================
-- Orbit Systems — Step 2 / Phase 3d: Transit Mode (3rd-party charter hub)
-- =============================================================================
-- Apply AFTER Phase 3c (Duval Wall). Idempotent. Run as postgres.
--
-- Lead Satellite tablets virtualize as the transit hub for charter buses
-- (activation threshold stored as 15 mph; edge telemetry enforces it).
--
-- Hierarchy (trip-scoped, not a replacement of staff_profiles.role):
--   primary_lead  — activate Transit Mode, lock tablet as hub
--   co_lead       — operate / assist; cannot lock or activate
--   basic         — presence only
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Hardware: Satellite tablets
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    cname text;
BEGIN
    SELECT con.conname INTO cname
    FROM pg_constraint con
    WHERE con.conrelid = 'public.trusted_hardware'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%device_type%';

    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE public.trusted_hardware DROP CONSTRAINT %I', cname);
    END IF;
END $$;

ALTER TABLE public.trusted_hardware
    ADD CONSTRAINT trusted_hardware_device_type_check
    CHECK (device_type IN (
        'Pilot_Tablet', 'Bay_Tablet', 'Node_Phone', 'Driver_BYOD', 'Satellite_Tablet'
    ));

-- -----------------------------------------------------------------------------
-- 1. Active trip columns
-- -----------------------------------------------------------------------------

ALTER TABLE public.trips
    ADD COLUMN IF NOT EXISTS is_transit_mode boolean NOT NULL DEFAULT false;

ALTER TABLE public.trips
    ADD COLUMN IF NOT EXISTS bus_assignment_type text NOT NULL DEFAULT 'fleet';

ALTER TABLE public.trips
    ADD COLUMN IF NOT EXISTS tablet_lock_timestamp timestamptz;

UPDATE public.trips
SET bus_assignment_type = 'fleet'
WHERE bus_assignment_type IS NULL
   OR bus_assignment_type NOT IN ('fleet', 'ext', '3rdparty');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'trips_bus_assignment_type_chk'
          AND conrelid = 'public.trips'::regclass
    ) THEN
        ALTER TABLE public.trips
            ADD CONSTRAINT trips_bus_assignment_type_chk
            CHECK (bus_assignment_type IN ('fleet', 'ext', '3rdparty'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'trips_transit_mode_assignment_chk'
          AND conrelid = 'public.trips'::regclass
    ) THEN
        ALTER TABLE public.trips
            ADD CONSTRAINT trips_transit_mode_assignment_chk
            CHECK (NOT is_transit_mode OR bus_assignment_type IN ('ext', '3rdparty'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'trips_tablet_lock_requires_transit_chk'
          AND conrelid = 'public.trips'::regclass
    ) THEN
        ALTER TABLE public.trips
            ADD CONSTRAINT trips_tablet_lock_requires_transit_chk
            CHECK (tablet_lock_timestamp IS NULL OR is_transit_mode);
    END IF;
END $$;

COMMENT ON COLUMN public.trips.is_transit_mode IS
    'True when a Satellite tablet is the virtual hub (charter / ext bus).';
COMMENT ON COLUMN public.trips.bus_assignment_type IS
    'fleet = district bus; ext = contracted carrier; 3rdparty = charter.';
COMMENT ON COLUMN public.trips.tablet_lock_timestamp IS
    'When the hub Satellite tablet was locked as the transit radio.';

-- -----------------------------------------------------------------------------
-- 2. satellite_units — physical Satellite tablets
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.satellite_units (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id uuid REFERENCES public.districts(id) ON DELETE RESTRICT,
    staff_id uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
    hardware_id uuid REFERENCES public.trusted_hardware(id) ON DELETE SET NULL,
    school_id uuid REFERENCES public.schools(id) ON DELETE SET NULL,
    unit_label text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT satellite_units_hardware_tenant_uq UNIQUE (tenant_id, hardware_id)
);

COMMENT ON TABLE public.satellite_units IS
    'Satellite tablet inventory. Bound to a staff member; may become a Transit Mode hub.';

CREATE INDEX IF NOT EXISTS satellite_units_staff_idx
    ON public.satellite_units (staff_id)
    WHERE is_active;

-- -----------------------------------------------------------------------------
-- 3. transit_trips — charter hub session for a trip
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.transit_trips (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id uuid REFERENCES public.districts(id) ON DELETE RESTRICT,
    trip_id uuid NOT NULL UNIQUE REFERENCES public.trips(id) ON DELETE RESTRICT,
    hub_satellite_unit_id uuid REFERENCES public.satellite_units(id) ON DELETE RESTRICT,
    charter_contractor_id uuid REFERENCES public.contractors(id) ON DELETE SET NULL,
    charter_carrier_name text,
    charter_vehicle_ref text,
    activation_speed_mph int NOT NULL DEFAULT 15
        CHECK (activation_speed_mph >= 0 AND activation_speed_mph <= 25),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'active', 'locked', 'completed', 'canceled')),
    activated_at timestamptz,
    tablet_lock_timestamp timestamptz,
    deactivated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.transit_trips IS
    'Virtual charter-hub session. Tablet becomes the bus radio at activation_speed_mph.';

CREATE INDEX IF NOT EXISTS transit_trips_status_idx
    ON public.transit_trips (tenant_id, status);

-- -----------------------------------------------------------------------------
-- 4. Trip-scoped Satellite hierarchy
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.transit_satellite_roster (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id uuid REFERENCES public.districts(id) ON DELETE RESTRICT,
    transit_trip_id uuid NOT NULL REFERENCES public.transit_trips(id) ON DELETE RESTRICT,
    trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
    satellite_unit_id uuid REFERENCES public.satellite_units(id) ON DELETE SET NULL,
    staff_id uuid NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
    hierarchy_role text NOT NULL
        CHECK (hierarchy_role IN ('primary_lead', 'co_lead', 'basic')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT transit_satellite_roster_staff_uq UNIQUE (transit_trip_id, staff_id)
);

COMMENT ON TABLE public.transit_satellite_roster IS
    'primary_lead / co_lead / basic assignments that gate Transit Mode actions.';

CREATE UNIQUE INDEX IF NOT EXISTS transit_roster_one_primary_lead_idx
    ON public.transit_satellite_roster (transit_trip_id)
    WHERE hierarchy_role = 'primary_lead';

CREATE INDEX IF NOT EXISTS transit_roster_trip_staff_idx
    ON public.transit_satellite_roster (trip_id, staff_id);

-- -----------------------------------------------------------------------------
-- 5. Access helpers + gates
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.satellite_role_allows_hierarchy(p_staff_role text, p_hierarchy text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT CASE p_hierarchy
        WHEN 'primary_lead' THEN p_staff_role IN (
            'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher', 'Command', 'Central'
        )
        WHEN 'co_lead' THEN p_staff_role IN (
            'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher', 'Command', 'Central'
        )
        WHEN 'basic' THEN p_staff_role IN (
            'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher', 'Sub_Teacher',
            'Command', 'Central'
        )
        ELSE false
    END
$$;

CREATE OR REPLACE FUNCTION public.transit_hierarchy_for(p_trip_id uuid, p_staff_id uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT r.hierarchy_role
    FROM public.transit_satellite_roster r
    WHERE r.trip_id = p_trip_id
      AND r.staff_id = p_staff_id
    LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.can_activate_transit_mode(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        public.get_my_role() IN ('Command', 'Central', 'Superintendent')
        OR public.transit_hierarchy_for(p_trip_id, auth.uid()) = 'primary_lead'
        OR EXISTS (
            SELECT 1 FROM public.trips t
            WHERE t.id = p_trip_id
              AND t.lead_satellite_id = auth.uid()
              AND NOT EXISTS (
                  SELECT 1 FROM public.transit_satellite_roster r
                  WHERE r.trip_id = p_trip_id
                    AND r.hierarchy_role = 'primary_lead'
              )
        )
$$;

CREATE OR REPLACE FUNCTION public.can_assist_transit_mode(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        public.can_activate_transit_mode(p_trip_id)
        OR public.transit_hierarchy_for(p_trip_id, auth.uid()) = 'co_lead'
$$;

REVOKE ALL ON FUNCTION public.satellite_role_allows_hierarchy(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transit_hierarchy_for(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_activate_transit_mode(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_assist_transit_mode(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.satellite_role_allows_hierarchy(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.transit_hierarchy_for(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_activate_transit_mode(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_assist_transit_mode(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.check_transit_roster_eligibility()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_role text;
BEGIN
    SELECT role INTO v_role FROM public.staff_profiles WHERE id = NEW.staff_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: staff_id is not a staff profile.'
            USING ERRCODE = '42501';
    END IF;
    IF NOT public.satellite_role_allows_hierarchy(v_role, NEW.hierarchy_role) THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: role % cannot be assigned hierarchy %',
            v_role, NEW.hierarchy_role
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_check_transit_roster_eligibility ON public.transit_satellite_roster;
CREATE TRIGGER trig_check_transit_roster_eligibility
    BEFORE INSERT OR UPDATE ON public.transit_satellite_roster
    FOR EACH ROW
    EXECUTE FUNCTION public.check_transit_roster_eligibility();

CREATE OR REPLACE FUNCTION public.gate_transit_mode_trip()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_changing boolean := false;
BEGIN
    IF current_setting('role', true) <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_changing := NEW.is_transit_mode OR NEW.tablet_lock_timestamp IS NOT NULL;
    ELSE
        v_changing :=
            NEW.is_transit_mode IS DISTINCT FROM OLD.is_transit_mode
            OR NEW.tablet_lock_timestamp IS DISTINCT FROM OLD.tablet_lock_timestamp
            OR NEW.bus_assignment_type IS DISTINCT FROM OLD.bus_assignment_type;
    END IF;

    IF v_changing AND NOT public.can_activate_transit_mode(NEW.id) THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: only primary_lead or Command may change Transit Mode'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_gate_transit_mode_trip ON public.trips;
CREATE TRIGGER trig_gate_transit_mode_trip
    BEFORE INSERT OR UPDATE ON public.trips
    FOR EACH ROW
    EXECUTE FUNCTION public.gate_transit_mode_trip();

CREATE OR REPLACE FUNCTION public.gate_transit_trip_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_locking boolean := false;
    v_activating boolean := false;
BEGIN
    IF current_setting('role', true) <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    v_activating :=
        NEW.status IN ('active', 'locked')
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status);
    v_locking :=
        NEW.tablet_lock_timestamp IS NOT NULL
        AND (TG_OP = 'INSERT' OR OLD.tablet_lock_timestamp IS DISTINCT FROM NEW.tablet_lock_timestamp);

    IF (v_activating OR v_locking) AND NOT public.can_activate_transit_mode(NEW.trip_id) THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: only primary_lead or Command may activate/lock Transit Mode'
            USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'UPDATE'
       AND NOT public.can_assist_transit_mode(NEW.trip_id)
    THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: basic Satellite cannot mutate transit_trips'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_gate_transit_trip_session ON public.transit_trips;
CREATE TRIGGER trig_gate_transit_trip_session
    BEFORE INSERT OR UPDATE ON public.transit_trips
    FOR EACH ROW
    EXECUTE FUNCTION public.gate_transit_trip_session();

-- Keep trips <-> transit_trips lock/mode in sync; seed primary_lead from lead_satellite_id.
CREATE OR REPLACE FUNCTION public.sync_transit_trip_from_trip()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tt uuid;
    v_tenant uuid;
    v_unit uuid;
BEGIN
    IF NOT NEW.is_transit_mode THEN
        UPDATE public.transit_trips
        SET status = CASE
                WHEN status IN ('completed', 'canceled') THEN status
                ELSE 'pending'
            END,
            tablet_lock_timestamp = NULL,
            updated_at = clock_timestamp()
        WHERE trip_id = NEW.id
          AND status IN ('pending', 'active', 'locked');
        RETURN NEW;
    END IF;

    v_tenant := COALESCE(NEW.tenant_id, NEW.district_id);

    SELECT su.id INTO v_unit
    FROM public.satellite_units su
    WHERE su.staff_id = NEW.lead_satellite_id
      AND su.is_active
    ORDER BY su.updated_at DESC
    LIMIT 1;

    INSERT INTO public.transit_trips (
        tenant_id, trip_id, hub_satellite_unit_id, status,
        activated_at, tablet_lock_timestamp
    )
    VALUES (
        v_tenant,
        NEW.id,
        v_unit,
        CASE WHEN NEW.tablet_lock_timestamp IS NOT NULL THEN 'locked' ELSE 'active' END,
        COALESCE(NEW.tablet_lock_timestamp, clock_timestamp()),
        NEW.tablet_lock_timestamp
    )
    ON CONFLICT (trip_id) DO UPDATE
    SET hub_satellite_unit_id = COALESCE(EXCLUDED.hub_satellite_unit_id, public.transit_trips.hub_satellite_unit_id),
        status = EXCLUDED.status,
        tablet_lock_timestamp = EXCLUDED.tablet_lock_timestamp,
        activated_at = COALESCE(public.transit_trips.activated_at, EXCLUDED.activated_at),
        tenant_id = COALESCE(public.transit_trips.tenant_id, EXCLUDED.tenant_id),
        updated_at = clock_timestamp()
    RETURNING id INTO v_tt;

    IF NEW.lead_satellite_id IS NOT NULL THEN
        INSERT INTO public.transit_satellite_roster (
            tenant_id, transit_trip_id, trip_id, satellite_unit_id, staff_id, hierarchy_role
        )
        VALUES (
            v_tenant, v_tt, NEW.id, v_unit, NEW.lead_satellite_id, 'primary_lead'
        )
        ON CONFLICT (transit_trip_id, staff_id) DO UPDATE
        SET hierarchy_role = 'primary_lead',
            satellite_unit_id = COALESCE(EXCLUDED.satellite_unit_id, public.transit_satellite_roster.satellite_unit_id);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_sync_transit_trip_from_trip ON public.trips;
CREATE TRIGGER trig_sync_transit_trip_from_trip
    AFTER INSERT OR UPDATE OF is_transit_mode, tablet_lock_timestamp, lead_satellite_id, tenant_id, district_id
    ON public.trips
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_transit_trip_from_trip();

CREATE OR REPLACE FUNCTION public.sync_trip_lock_from_transit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.trips
    SET is_transit_mode = (NEW.status IN ('active', 'locked')),
        tablet_lock_timestamp = NEW.tablet_lock_timestamp,
        updated_at = clock_timestamp()
    WHERE id = NEW.trip_id
      AND (
          is_transit_mode IS DISTINCT FROM (NEW.status IN ('active', 'locked'))
          OR tablet_lock_timestamp IS DISTINCT FROM NEW.tablet_lock_timestamp
      );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_sync_trip_lock_from_transit ON public.transit_trips;
CREATE TRIGGER trig_sync_trip_lock_from_transit
    AFTER INSERT OR UPDATE OF status, tablet_lock_timestamp
    ON public.transit_trips
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_trip_lock_from_transit();

-- -----------------------------------------------------------------------------
-- 6. Duval Wall on new tables (do not reopen the perimeter)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    t text;
    new_tables text[] := ARRAY[
        'satellite_units',
        'transit_trips',
        'transit_satellite_roster'
    ];
BEGIN
    FOREACH t IN ARRAY new_tables LOOP
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I (tenant_id)', t || '_tenant_id_idx', t);
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);

        EXECUTE format('DROP TRIGGER IF EXISTS trig_duval_stamp_tenant ON public.%I', t);
        EXECUTE format(
            'CREATE TRIGGER trig_duval_stamp_tenant
             BEFORE INSERT OR UPDATE ON public.%I
             FOR EACH ROW
             EXECUTE FUNCTION public.duval_stamp_tenant_id()',
            t
        );

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at')
           AND EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = t AND column_name = 'updated_at'
           )
        THEN
            EXECUTE format('DROP TRIGGER IF EXISTS trig_set_updated_%I ON public.%I', t, t);
            EXECUTE format(
                'CREATE TRIGGER trig_set_updated_%I
                 BEFORE UPDATE ON public.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.set_updated_at()',
                t, t
            );
        END IF;

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'process_forensic_audit') THEN
            EXECUTE format('DROP TRIGGER IF EXISTS trig_audit_%I ON public.%I', t, t);
            EXECUTE format(
                'CREATE TRIGGER trig_audit_%I
                 AFTER INSERT OR UPDATE OR DELETE ON public.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.process_forensic_audit()',
                t, t
            );
        END IF;

        EXECUTE format('DROP POLICY IF EXISTS duval_deny_all ON public.%I', t);
        EXECUTE format(
            'CREATE POLICY duval_deny_all ON public.%I
             AS RESTRICTIVE FOR ALL TO anon
             USING (false) WITH CHECK (false)',
            t
        );

        EXECUTE format('DROP POLICY IF EXISTS duval_tenant_isolation ON public.%I', t);
        EXECUTE format(
            'CREATE POLICY duval_tenant_isolation ON public.%I
             AS RESTRICTIVE FOR ALL TO authenticated
             USING (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)
             WITH CHECK (tenant_id = (auth.jwt() ->> ''tenant_id'')::uuid)',
            t
        );

        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon', t);
        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated, service_role',
            t
        );
    END LOOP;
END $$;

DROP POLICY IF EXISTS satellite_units_staff_all ON public.satellite_units;
CREATE POLICY satellite_units_staff_all ON public.satellite_units
    FOR ALL TO authenticated
    USING (
        staff_id = auth.uid()
        OR public.get_my_role() IN (
            'Command', 'Central', 'Superintendent', 'Principal',
            'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher'
        )
    )
    WITH CHECK (
        staff_id = auth.uid()
        OR public.get_my_role() IN (
            'Command', 'Central', 'Superintendent', 'Principal', 'Lead_Satellite'
        )
    );

DROP POLICY IF EXISTS transit_trips_staff_select ON public.transit_trips;
CREATE POLICY transit_trips_staff_select ON public.transit_trips
    FOR SELECT TO authenticated
    USING (
        public.get_my_role() IN (
            'Command', 'Central', 'Superintendent', 'Principal',
            'Pilot', 'Halo', 'Lead_Satellite', 'Satellite',
            'Staff_Teacher', 'Teacher', 'Sub_Teacher'
        )
        OR EXISTS (
            SELECT 1 FROM public.transit_satellite_roster r
            WHERE r.transit_trip_id = transit_trips.id
              AND r.staff_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS transit_trips_staff_write ON public.transit_trips;
CREATE POLICY transit_trips_staff_write ON public.transit_trips
    FOR INSERT TO authenticated
    WITH CHECK (public.can_assist_transit_mode(trip_id) OR public.can_activate_transit_mode(trip_id));

DROP POLICY IF EXISTS transit_trips_staff_update ON public.transit_trips;
CREATE POLICY transit_trips_staff_update ON public.transit_trips
    FOR UPDATE TO authenticated
    USING (public.can_assist_transit_mode(trip_id))
    WITH CHECK (public.can_assist_transit_mode(trip_id));

DROP POLICY IF EXISTS transit_roster_staff_select ON public.transit_satellite_roster;
CREATE POLICY transit_roster_staff_select ON public.transit_satellite_roster
    FOR SELECT TO authenticated
    USING (
        staff_id = auth.uid()
        OR public.get_my_role() IN (
            'Command', 'Central', 'Superintendent', 'Principal',
            'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher'
        )
    );

DROP POLICY IF EXISTS transit_roster_lead_write ON public.transit_satellite_roster;
CREATE POLICY transit_roster_lead_write ON public.transit_satellite_roster
    FOR ALL TO authenticated
    USING (
        public.can_activate_transit_mode(trip_id)
        OR public.get_my_role() IN ('Command', 'Central')
    )
    WITH CHECK (
        public.can_activate_transit_mode(trip_id)
        OR public.get_my_role() IN ('Command', 'Central')
    );

COMMIT;
