#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
NON_GITHUB_ROOT="${NON_GITHUB_ROOT:-${WORKSPACE_ROOT}/EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB}"

NAMESPACE="${NAMESPACE:-epydios-system}"
CLUSTER_NAME="${CLUSTER_NAME:-epydios-postgres}"
APP_DATABASE="${APP_DATABASE:-aios_core}"
RESTORE_DATABASE="${RESTORE_DATABASE:-aios_core_restore_drill}"
SUPERUSER_SECRET="${SUPERUSER_SECRET:-epydios-postgres-superuser}"
BACKUP_TABLE="${BACKUP_TABLE:-epydios_backup_restore_drill}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
CLEANUP_RESTORE_DATABASE="${CLEANUP_RESTORE_DATABASE:-1}"
KEEP_DUMP_FILE="${KEEP_DUMP_FILE:-0}"

MAX_RPO_SECONDS="${MAX_RPO_SECONDS:-300}"
MAX_RTO_SECONDS="${MAX_RTO_SECONDS:-900}"

OUTPUT_DIR="${OUTPUT_DIR:-${NON_GITHUB_ROOT}/provenance/dr-gameday}"
MARKER="${MARKER:-m12-dr-gameday-$(date +%Y%m%d%H%M%S)}"

TMPDIR_LOCAL="$(mktemp -d)"
DUMP_FILE="${TMPDIR_LOCAL}/aios_core_backup.sql"
PRIMARY_POD=""
PGUSER_VALUE=""
PGPASSWORD_VALUE=""

dump_diagnostics() {
  echo
  echo "=== M12.2 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get cluster,backup,scheduledbackup,pods,svc >&2 || true
  kubectl -n "${NAMESPACE}" describe "cluster.postgresql.cnpg.io/${CLUSTER_NAME}" >&2 || true
  if [ -n "${PRIMARY_POD}" ]; then
    kubectl -n "${NAMESPACE}" logs "${PRIMARY_POD}" --tail=200 >&2 || true
  fi
}

cleanup() {
  if [ "${KEEP_DUMP_FILE}" = "1" ]; then
    echo "Keeping dump artifact at: ${DUMP_FILE}"
    return 0
  fi
  rm -rf "${TMPDIR_LOCAL}"
}
trap cleanup EXIT
trap dump_diagnostics ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

b64decode_stdin() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

secret_key() {
  local secret_name="$1"
  local key="$2"
  local b64
  b64="$(kubectl -n "${NAMESPACE}" get secret "${secret_name}" -o "go-template={{index .data \"${key}\"}}" 2>/dev/null || true)"
  if [ -z "${b64}" ]; then
    echo "Missing secret key: ${NAMESPACE}/${secret_name} key=${key}" >&2
    return 1
  fi
  printf '%s' "${b64}" | b64decode_stdin
}

wait_for_cluster_ready() {
  kubectl -n "${NAMESPACE}" wait \
    --for=condition=Ready \
    "cluster.postgresql.cnpg.io/${CLUSTER_NAME}" \
    --timeout="${TIMEOUT_SECONDS}s" >/dev/null
}

discover_primary_pod() {
  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pod \
    -l "cnpg.io/cluster=${CLUSTER_NAME},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    pod="$(kubectl -n "${NAMESPACE}" get pod \
      -l "cnpg.io/cluster=${CLUSTER_NAME},cnpg.io/instanceRole=primary" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [ -z "${pod}" ]; then
    echo "Unable to resolve CNPG primary pod for cluster ${CLUSTER_NAME}" >&2
    return 1
  fi
  PRIMARY_POD="${pod}"
}

psql_exec_stdin() {
  local database="$1"
  kubectl -n "${NAMESPACE}" exec -i "${PRIMARY_POD}" -- env \
    PGPASSWORD="${PGPASSWORD_VALUE}" \
    psql -v ON_ERROR_STOP=1 -U "${PGUSER_VALUE}" -d "${database}" -f -
}

psql_query_scalar() {
  local database="$1"
  local sql="$2"
  kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -- env \
    PGPASSWORD="${PGPASSWORD_VALUE}" \
    psql -At -v ON_ERROR_STOP=1 -U "${PGUSER_VALUE}" -d "${database}" -c "${sql}" 2>/dev/null | tr -d '[:space:]'
}

seed_source_state() {
  cat <<SQL | psql_exec_stdin "${APP_DATABASE}" >/dev/null
CREATE TABLE IF NOT EXISTS public.${BACKUP_TABLE} (
  id BIGSERIAL PRIMARY KEY,
  marker TEXT NOT NULL UNIQUE,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.${BACKUP_TABLE}(marker)
VALUES ('${MARKER}')
ON CONFLICT (marker) DO UPDATE SET inserted_at = now();
SQL
}

backup_source_database() {
  kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -- env \
    PGPASSWORD="${PGPASSWORD_VALUE}" \
    pg_dump -U "${PGUSER_VALUE}" -d "${APP_DATABASE}" --no-owner --no-privileges --format=plain >"${DUMP_FILE}"
}

simulate_data_loss() {
  cat <<SQL | psql_exec_stdin "${APP_DATABASE}" >/dev/null
DELETE FROM public.${BACKUP_TABLE} WHERE marker = '${MARKER}';
SQL
}

recreate_restore_database() {
  cat <<SQL | psql_exec_stdin postgres >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${RESTORE_DATABASE}'
  AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${RESTORE_DATABASE};
CREATE DATABASE ${RESTORE_DATABASE};
SQL
}

restore_dump() {
  kubectl -n "${NAMESPACE}" exec -i "${PRIMARY_POD}" -- env \
    PGPASSWORD="${PGPASSWORD_VALUE}" \
    psql -v ON_ERROR_STOP=1 -U "${PGUSER_VALUE}" -d "${RESTORE_DATABASE}" -f - <"${DUMP_FILE}" >/dev/null
}

cleanup_restore_database() {
  if [ "${CLEANUP_RESTORE_DATABASE}" != "1" ]; then
    return 0
  fi

  cat <<SQL | psql_exec_stdin postgres >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${RESTORE_DATABASE}'
  AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${RESTORE_DATABASE};
SQL
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "${expected}" != "${actual}" ]; then
    echo "Assertion failed for ${label}: expected=${expected} actual=${actual}" >&2
    return 1
  fi
}

assert_leq() {
  local actual="$1"
  local max="$2"
  local label="$3"
  if [ "${actual}" -gt "${max}" ]; then
    echo "Assertion failed for ${label}: actual=${actual}s max=${max}s" >&2
    return 1
  fi
}

main() {
  require_cmd kubectl
  require_cmd base64
  require_cmd jq

  mkdir -p "${OUTPUT_DIR}"

  local drill_started_at restore_started_at restore_ended_at drill_ended_at
  local marker_epoch backup_started_at backup_ended_at
  local pre_backup_count after_loss_count restored_count
  local computed_rpo_seconds computed_rto_seconds drill_duration_seconds
  local out_json out_latest out_sha

  drill_started_at="$(date -u +%s)"

  wait_for_cluster_ready
  discover_primary_pod

  PGUSER_VALUE="$(secret_key "${SUPERUSER_SECRET}" username)"
  PGPASSWORD_VALUE="$(secret_key "${SUPERUSER_SECRET}" password)"
  if [ -z "${PGUSER_VALUE}" ] || [ -z "${PGPASSWORD_VALUE}" ]; then
    echo "Unable to load Postgres superuser credentials from secret ${SUPERUSER_SECRET}" >&2
    exit 1
  fi

  echo "M12.2: seeding source state in ${APP_DATABASE} (marker=${MARKER})..."
  seed_source_state

  pre_backup_count="$(psql_query_scalar "${APP_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "1" "${pre_backup_count}" "pre-backup marker count"

  marker_epoch="$(psql_query_scalar "${APP_DATABASE}" "SELECT COALESCE(floor(EXTRACT(EPOCH FROM inserted_at))::bigint,0) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}' LIMIT 1;")"
  if [ -z "${marker_epoch}" ] || [ "${marker_epoch}" = "0" ]; then
    echo "Unable to compute marker inserted_at epoch for marker=${MARKER}" >&2
    exit 1
  fi

  echo "M12.2: creating logical backup (${DUMP_FILE})..."
  backup_started_at="$(date -u +%s)"
  backup_source_database
  backup_ended_at="$(date -u +%s)"

  computed_rpo_seconds=$((backup_ended_at - marker_epoch))
  if [ "${computed_rpo_seconds}" -lt 0 ]; then
    computed_rpo_seconds=0
  fi
  assert_leq "${computed_rpo_seconds}" "${MAX_RPO_SECONDS}" "RPO threshold"

  echo "M12.2: simulating source data loss..."
  simulate_data_loss
  after_loss_count="$(psql_query_scalar "${APP_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "0" "${after_loss_count}" "post-loss marker count"

  echo "M12.2: restoring backup into ${RESTORE_DATABASE}..."
  restore_started_at="$(date -u +%s)"
  recreate_restore_database
  restore_dump
  restore_ended_at="$(date -u +%s)"

  restored_count="$(psql_query_scalar "${RESTORE_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "1" "${restored_count}" "restored marker count"

  computed_rto_seconds=$((restore_ended_at - restore_started_at))
  if [ "${computed_rto_seconds}" -lt 0 ]; then
    computed_rto_seconds=0
  fi
  assert_leq "${computed_rto_seconds}" "${MAX_RTO_SECONDS}" "RTO threshold"

  cleanup_restore_database

  drill_ended_at="$(date -u +%s)"
  drill_duration_seconds=$((drill_ended_at - drill_started_at))
  if [ "${drill_duration_seconds}" -lt 0 ]; then
    drill_duration_seconds=0
  fi

  out_json="${OUTPUT_DIR}/m12-2-dr-gameday-$(date -u +%Y%m%dT%H%M%SZ).json"
  out_latest="${OUTPUT_DIR}/m12-2-dr-gameday-latest.json"

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cluster "${CLUSTER_NAME}" \
    --arg namespace "${NAMESPACE}" \
    --arg source_db "${APP_DATABASE}" \
    --arg restore_db "${RESTORE_DATABASE}" \
    --arg marker "${MARKER}" \
    --arg marker_epoch "${marker_epoch}" \
    --arg backup_started_at "${backup_started_at}" \
    --arg backup_ended_at "${backup_ended_at}" \
    --arg restore_started_at "${restore_started_at}" \
    --arg restore_ended_at "${restore_ended_at}" \
    --arg max_rpo_seconds "${MAX_RPO_SECONDS}" \
    --arg max_rto_seconds "${MAX_RTO_SECONDS}" \
    --arg computed_rpo_seconds "${computed_rpo_seconds}" \
    --arg computed_rto_seconds "${computed_rto_seconds}" \
    --arg drill_duration_seconds "${drill_duration_seconds}" \
    --arg dump_file "${DUMP_FILE}" \
    --arg keep_dump_file "${KEEP_DUMP_FILE}" \
    '{
      generatedAt: $generated_at,
      phase: "M12.2",
      check: "dr-gameday-rpo-rto",
      status: "pass",
      cluster: $cluster,
      namespace: $namespace,
      sourceDatabase: $source_db,
      restoreDatabase: $restore_db,
      marker: $marker,
      markerEpochSeconds: ($marker_epoch|tonumber),
      backupWindow: {
        startedAtEpochSeconds: ($backup_started_at|tonumber),
        endedAtEpochSeconds: ($backup_ended_at|tonumber)
      },
      restoreWindow: {
        startedAtEpochSeconds: ($restore_started_at|tonumber),
        endedAtEpochSeconds: ($restore_ended_at|tonumber)
      },
      thresholds: {
        maxRPOSeconds: ($max_rpo_seconds|tonumber),
        maxRTOSeconds: ($max_rto_seconds|tonumber)
      },
      observed: {
        rpoSeconds: ($computed_rpo_seconds|tonumber),
        rtoSeconds: ($computed_rto_seconds|tonumber),
        drillDurationSeconds: ($drill_duration_seconds|tonumber)
      },
      artifacts: {
        dumpFile: $dump_file,
        keepDumpFile: ($keep_dump_file == "1")
      }
    }' >"${out_json}"

  cp "${out_json}" "${out_latest}"
  out_sha="sha256:$(sha256_file "${out_json}")"
  printf '%s  %s\n' "${out_sha}" "$(basename "${out_json}")" >"${out_json}.sha256"
  printf '%s  %s\n' "${out_sha}" "$(basename "${out_latest}")" >"${out_latest}.sha256"

  echo
  echo "M12.2 DR game-day verification passed."
  echo "  cluster=${CLUSTER_NAME}"
  echo "  source_db=${APP_DATABASE}"
  echo "  restore_db=${RESTORE_DATABASE}"
  echo "  marker=${MARKER}"
  echo "  observed_rpo_seconds=${computed_rpo_seconds} (max=${MAX_RPO_SECONDS})"
  echo "  observed_rto_seconds=${computed_rto_seconds} (max=${MAX_RTO_SECONDS})"
  echo "  evidence=${out_json}"
  echo "  evidence_sha256=${out_sha}"
}

main "$@"
