-- Phase 3 — updated_at on tables that have the column

BEGIN;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables tb
          ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND c.column_name = 'updated_at'
          AND tb.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trig_set_updated_%I ON public.%I', t, t);
        EXECUTE format(
            'CREATE TRIGGER trig_set_updated_%I
             BEFORE UPDATE ON public.%I
             FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
            t, t
        );
    END LOOP;
END $$;

COMMIT;
