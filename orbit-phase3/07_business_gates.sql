-- Phase 3 — Minimal business gates (expand in Phase 3b)

BEGIN;

CREATE OR REPLACE FUNCTION public.check_trip_lead_clearance()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.lead_satellite_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.staff_profiles
        WHERE id = NEW.lead_satellite_id
          AND role IN ('Satellite', 'Teacher', 'Staff_Teacher', 'Lead_Satellite', 'Command', 'Central')
    ) THEN
        RAISE EXCEPTION 'AUTHORITY_ERROR: Invalid lead_satellite_id role.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trig_check_trip_lead_clearance ON public.trips;
CREATE TRIGGER trig_check_trip_lead_clearance
    BEFORE INSERT OR UPDATE ON public.trips
    FOR EACH ROW
    EXECUTE FUNCTION public.check_trip_lead_clearance();

COMMIT;
