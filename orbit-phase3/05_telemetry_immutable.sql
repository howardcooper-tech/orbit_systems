-- Phase 3 — bus_telemetry_logs INSERT-only (Orbit Atom SPEC)

BEGIN;

CREATE OR REPLACE FUNCTION public.deny_telemetry_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE: bus_telemetry_logs allows INSERT only.';
END;
$$;

DROP TRIGGER IF EXISTS trig_telemetry_insert_only ON public.bus_telemetry_logs;
CREATE TRIGGER trig_telemetry_insert_only
    BEFORE UPDATE OR DELETE ON public.bus_telemetry_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.deny_telemetry_mutation();

-- No audit trigger on telemetry (append-only stream; denylist in 04)

COMMIT;
