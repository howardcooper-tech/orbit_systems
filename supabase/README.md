# Supabase folder

- Run `supabase link --project-ref <ref>` from repo root (`orbit-systems/`).
- Optional: add `migrations/<timestamp>_phase1.sql` copied from `../orbit-phase1/` for `supabase db push`.
- Primary deploy path for Orbit remains **`orbit-tools/run-orbit.ps1`** (manifest order).

Do not commit database passwords here.
