#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-epydios-system}"
CLUSTER_NAME="${CLUSTER_NAME:-epydios-postgres}"
APP_DATABASE="${APP_DATABASE:-aios_core}"
RESTORE_DATABASE="${RESTORE_DATABASE:-aios_core_restore_drill}"
SUPERUSER_SECRET="${SUPERUSER_SECRET:-epydios-postgres-superuser}"
BACKUP_TABLE="${BACKUP_TABLE:-epydios_backup_restore_drill}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
CLEANUP_RESTORE_DATABASE="${CLEANUP_RESTORE_DATABASE:-1}"
KEEP_DUMP_FILE="${KEEP_DUMP_FILE:-0}"
MARKER="${MARKER:-m7-backup-restore-$(date +%Y%m%d%H%M%S)}"

TMPDIR_LOCAL="$(mktemp -d)"
DUMP_FILE="${TMPDIR_LOCAL}/aios_core_backup.sql"
PRIMARY_POD=""
PGUSER_VALUE=""
PGPASSWORD_VALUE=""

dump_diagnostics() {
  echo
  echo "=== M7.2 diagnostics (${NAMESPACE}) ===" >&2
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

main() {
  require_cmd kubectl
  require_cmd base64

  wait_for_cluster_ready
  discover_primary_pod

  PGUSER_VALUE="$(secret_key "${SUPERUSER_SECRET}" username)"
  PGPASSWORD_VALUE="$(secret_key "${SUPERUSER_SECRET}" password)"

  if [ -z "${PGUSER_VALUE}" ] || [ -z "${PGPASSWORD_VALUE}" ]; then
    echo "Unable to load Postgres superuser credentials from secret ${SUPERUSER_SECRET}" >&2
    exit 1
  fi

  echo "M7.2: seeding source state in ${APP_DATABASE} (marker=${MARKER})..."
  seed_source_state

  local pre_backup_count
  pre_backup_count="$(psql_query_scalar "${APP_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "1" "${pre_backup_count}" "pre-backup marker count"

  echo "M7.2: creating logical backup (${DUMP_FILE})..."
  backup_source_database

  echo "M7.2: simulating loss in source database..."
  simulate_data_loss
  local after_loss_count
  after_loss_count="$(psql_query_scalar "${APP_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "0" "${after_loss_count}" "post-loss marker count"

  echo "M7.2: restoring backup into ${RESTORE_DATABASE}..."
  recreate_restore_database
  restore_dump

  local restored_count
  restored_count="$(psql_query_scalar "${RESTORE_DATABASE}" "SELECT count(*) FROM public.${BACKUP_TABLE} WHERE marker='${MARKER}';")"
  assert_equals "1" "${restored_count}" "restored marker count"

  cleanup_restore_database

  echo
  echo "M7.2 CNPG backup/restore drill passed."
  echo "  cluster=${CLUSTER_NAME}"
  echo "  source_db=${APP_DATABASE}"
  echo "  restore_db=${RESTORE_DATABASE}"
  echo "  marker=${MARKER}"
  if [ "${KEEP_DUMP_FILE}" = "1" ]; then
    echo "  dump_file=${DUMP_FILE}"
  fi
}

main "$@"
