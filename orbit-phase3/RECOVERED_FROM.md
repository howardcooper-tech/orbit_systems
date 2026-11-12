# Recovered definitions

These three files were copied verbatim from `orbit_systems` commit `0463da39d53455e5efe713fb0a7d4892feb2dc55` on branch `cursor/phase-3c-duval-wall`:

- `08_phase_3c_duval_wall.sql` — `jwt_tenant_id()`, `duval_stamp_tenant_id()`, `audit_worm_ledger`
- `10_auth_tenant_jwt_hook.sql` — `resolve_orbit_tenant_id()`, `custom_access_token_hook()`
- `13_rescue_bus_protocol.sql` — `transfer_manifest_to_rescue(uuid, uuid)`

They were not on `main`. They have not been executed in this recovery. They have not been compared with the live function bodies in staging, because no read-only database credential was available.

Do not edit the function bodies to “make them fit.” Do not run `orbit-phase1/00_sweep_reset_staging.sql`.

`resolve_orbit_web_experience()` and the Central Express objects are not in this commit and are not in any other branch that was searched.
