-- Phase 3 — Forensic audit triggers (documented denylist)

BEGIN;

DO $$
DECLARE
    t TEXT;
    denylist TEXT[] := ARRAY['audit_logs', 'bus_telemetry_logs', 'spatial_ref_sys'];
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        IF t = ANY (denylist) THEN
            CONTINUE;
        END IF;
        EXECUTE format('DROP TRIGGER IF EXISTS trig_audit_%I ON public.%I', t, t);
        EXECUTE format(
            'CREATE TRIGGER trig_audit_%I
             AFTER INSERT OR UPDATE OR DELETE ON public.%I
             FOR EACH ROW EXECUTE FUNCTION public.process_forensic_audit()',
            t, t
        );
    END LOOP;
END $$;

COMMIT;
