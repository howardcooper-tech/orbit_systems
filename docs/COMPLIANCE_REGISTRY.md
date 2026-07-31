# Compliance registry (evidence index)

Auditors and district partners ask for **artifacts**, not chat logs. Index what ran, where, and when.

| Artifact | Path | Notes |
|----------|------|--------|
| Phase 1 schema | `orbit-phase1/*.sql` | Structure only |
| Phase 2 SIS | `orbit-phase2/*.sql` | Helpers + optional seed |
| Phase 3 security | `orbit-phase3/*.sql` | RLS, audit, gates |
| Deploy manifest | `orbit-tools/manifest.json` | Run order |
| Deploy runner | `orbit-tools/run-orbit.ps1` | Operator/CI |
| Stack wiring | `STACK.md` | GitHub ↔ Supabase |
| Field trip 15/10 protocol | `docs/FIELD_TRIP_15_10_PROTOCOL.md` | Point notify + after-action rules |

## Run log (fill in per environment)

| Date | Environment | Phases run | Operator | Git commit |
|------|-------------|------------|----------|------------|
| | staging | 1–3 | | |

## Supabase project

- Project ref: _(after `supabase link`)_
- Region: _
- PITR enabled: yes / no
- Branch used for pilot: _
