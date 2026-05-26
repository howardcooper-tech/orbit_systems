# Orbit Systems (Atom)

Hardened Postgres core for Orbit Atom: phased schema (1–3), Supabase-hosted DB, operator deploy scripts.

## Repo layout

| Path | Role |
|------|------|
| `orbit-phase1/` | Structure — tables, FKs, indexes |
| `orbit-phase2/` | SIS handshake / import helpers |
| `orbit-phase3/` | Functions, RLS (Duval Wall), audit, gates |
| `orbit-tools/` | Manifest-driven deploy (`run-orbit.ps1`) |
| `supabase/` | CLI project link + optional migrations |
| `docs/` | Compliance index + operational protocols |
| `STACK.md` | **How to link GitHub ↔ Supabase ↔ deploy** |

## Key docs

| Document | Purpose |
|----------|---------|
| [docs/FIELD_TRIP_15_10_PROTOCOL.md](./docs/FIELD_TRIP_15_10_PROTOCOL.md) | Field trip missing-child **15/10** timer, Point notification rules, after-action report |
| [docs/COMPLIANCE_REGISTRY.md](./docs/COMPLIANCE_REGISTRY.md) | Evidence index for auditors / district partners |

## Quick start (operator)

1. Clone this repo locally.
2. Copy phase SQL from your working folder if needed: `.\scripts\Sync-From-Documents.ps1`
3. Follow **[STACK.md](./STACK.md)** to link Supabase and run Phase 3 deploy.
4. Do **not** commit `.env` or database passwords.

## Remote

GitHub: `howardcooper-tech/orbit_systems`

Supabase project is linked via `supabase link` (project ref in `supabase/config.toml` after link) — not stored as secrets in git.
