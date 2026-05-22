#!/usr/bin/env bash
# Run Orbit Atom phase SQL in order (operator / CI — not for end-user clients).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PHASE="${1:-3}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_DEV_SEED="${INCLUDE_DEV_SEED:-0}"
INCLUDE_SWEEP="${INCLUDE_SWEEP:-0}"
INCLUDE_PREFLIGHT="${INCLUDE_PREFLIGHT:-0}"
INCLUDE_VERIFY="${INCLUDE_VERIFY:-0}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

run_sql() {
  local file="$1"
  local label="$2"
  echo ""
  echo "==> $label"
  echo "    $file"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    [dry-run] skipped"
    return 0
  fi
  if [[ -n "${ORBIT_DATABASE_URL:-}" ]]; then
    psql "$ORBIT_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$file"
  elif [[ "${ORBIT_USE_SUPABASE_CLI:-}" == "1" ]]; then
    supabase db execute -f "$file"
  else
    echo "No ORBIT_DATABASE_URL or ORBIT_USE_SUPABASE_CLI=1 configured." >&2
    exit 1
  fi
}

should_run_optional() {
  local file="$1"
  local destructive="${2:-0}"
  if [[ "$destructive" == "1" && "$INCLUDE_SWEEP" == "1" ]]; then return 0; fi
  if [[ "$file" == "03_dev_seed_optional.sql" && "$INCLUDE_DEV_SEED" == "1" ]]; then return 0; fi
  if [[ "$file" == "01_preflight_checks.sql" && "$INCLUDE_PREFLIGHT" == "1" ]]; then return 0; fi
  if [[ "$file" == "PHASE1_VERIFY.sql" && "$INCLUDE_VERIFY" == "1" ]]; then return 0; fi
  return 1
}

run_phase() {
  local key="$1"
  local dir phase_label
  case "$key" in
    1) dir="orbit-phase1"; phase_label="Structure" ;;
    2) dir="orbit-phase2"; phase_label="SIS handshake" ;;
    3) dir="orbit-phase3"; phase_label="Brain (RLS)" ;;
    *) echo "Unknown phase: $key" >&2; exit 1 ;;
  esac

  echo ""
  echo "######## Phase $key — $phase_label ########"

  local -a files
  case "$key" in
    1)
      files=(
        "00_sweep_reset_staging.sql:1:1"
        "01_extensions.sql:0:0"
        "02_infrastructure.sql:0:0"
        "03_students_sis.sql:0:0"
        "04_fleet.sql:0:0"
        "05_trips.sql:0:0"
        "06_bay_comms.sql:0:0"
        "07_mesh_iot.sql:0:0"
        "08_emergency.sql:0:0"
        "09_field_routes.sql:0:0"
        "10_halo_alerts.sql:0:0"
        "11_archive_schema.sql:0:0"
        "12_indexes.sql:0:0"
        "PHASE1_VERIFY.sql:0:0"
      )
      ;;
    2)
      files=(
        "01_preflight_checks.sql:0:0"
        "02_sis_import_helpers.sql:0:0"
        "03_dev_seed_optional.sql:0:0"
      )
      ;;
    3)
      files=(
        "01_core_functions.sql:0:0"
        "02_enable_rls.sql:0:0"
        "03_rls_duval_wall.sql:0:0"
        "04_audit_triggers.sql:0:0"
        "05_telemetry_immutable.sql:0:0"
        "06_updated_at_triggers.sql:0:0"
        "07_business_gates.sql:0:0"
      )
      ;;
  esac

  for entry in "${files[@]}"; do
    IFS=':' read -r fname optional destructive <<< "$entry"
    if [[ "$optional" == "1" ]] && ! should_run_optional "$fname" "$destructive"; then
      echo "    [skip optional] $fname"
      continue
    fi
    run_sql "$DOCS_ROOT/$dir/$fname" "Phase $key / $fname"
  done
}

echo "Orbit deploy runner (bash)"
echo "  Root: $DOCS_ROOT"

case "$PHASE" in
  1|2|3) run_phase "$PHASE" ;;
  all)
    run_phase 1
    run_phase 2
    run_phase 3
    ;;
  *)
    echo "Usage: ./run-orbit.sh [1|2|3|all]" >&2
    echo "  Env: ORBIT_DATABASE_URL, DRY_RUN=1, INCLUDE_DEV_SEED=1, INCLUDE_SWEEP=1" >&2
    exit 1
    ;;
esac

echo ""
echo "Done."
