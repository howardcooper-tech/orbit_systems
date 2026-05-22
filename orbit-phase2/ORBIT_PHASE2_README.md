# Orbit Atom — Phase 2 (Data / SIS Handshake)

Run **after Phase 1** succeeds and `PHASE1_VERIFY.sql` looks good.

Phase 2 does **not** add triggers or RLS. It prepares data rules and optional dev seed.

## Run order

| # | File | Purpose |
|---|------|---------|
| 1 | `01_preflight_checks.sql` | Read-only: duplicates, orphans (run in SQL editor) |
| 2 | `02_sis_import_helpers.sql` | `link_sis_account()` + import comments |
| 3 | `03_dev_seed_optional.sql` | **Optional** — one district, school, students for UI testing |

Skip `03_dev_seed_optional.sql` when loading real SIS CSV/API in production.

## Insert order (always)

1. `districts` → `schools` → `contractors`
2. `student_sis_enrollment` (macro / SIS row)
3. `students` (micro / BLE row, same `sis_student_id`)
4. `student_guardians`, `trip_manifest`, etc.

## Real SIS load (production path)

Import into `student_sis_enrollment` first with columns:

- `sis_student_id` (district unique ID)
- `school_id`, `full_name`, `date_of_birth`, `enrollment_status`

Then insert matching `students` rows with the same `sis_student_id`.

## Next

Phase 3: `../orbit-phase3/` — functions, Duval Wall RLS, audit triggers, telemetry INSERT-only.
