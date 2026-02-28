#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-kind}"               # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
RUN_BOOTSTRAP="${RUN_BOOTSTRAP:-1}"      # 1 runs bootstrap first; 0 only verifies current cluster
NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

BOOTSTRAP_STATUS="SKIPPED"

check_results=()
check_details=()

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

run_bootstrap() {
  local script
  case "${RUNTIME}" in
    kind) script="${SCRIPT_DIR}/bootstrap-kind.sh" ;;
    k3d) script="${SCRIPT_DIR}/bootstrap-k3d.sh" ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected 'kind' or 'k3d')." >&2
      exit 1
      ;;
  esac

  if [ "${RUN_BOOTSTRAP}" != "1" ]; then
    BOOTSTRAP_STATUS="SKIPPED"
    return 0
  fi

  echo "Running M0 bootstrap (${RUNTIME}) with provider discovery smoke..."
  if CLUSTER_NAME="${CLUSTER_NAME}" WITH_SYSTEM_SMOKETEST=1 "${script}"; then
    BOOTSTRAP_STATUS="PASS"
  else
    BOOTSTRAP_STATUS="FAIL"
    echo "Bootstrap reported failure; continuing to collect M0 check results." >&2
  fi
}

record_check() {
  local name="$1"
  local status="$2"
  local detail="$3"
  check_results+=("${name}:${status}")
  check_details+=("${name}:${detail}")
}

has_condition() {
  local namespace="$1"
  local resource="$2"
  local cond_type="$3"
  local expected="$4"
  local lines

  lines="$(
    kubectl -n "${namespace}" get "${resource}" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true
  )"
  printf '%s\n' "${lines}" | awk -F= -v t="${cond_type}" -v e="${expected}" '$1==t && $2==e { found=1 } END { exit(found ? 0 : 1) }'
}

wait_for_condition() {
  local namespace="$1"
  local resource="$2"
  local cond_type="$3"
  local expected="$4"
  local start

  start="$(date +%s)"
  while true; do
    if has_condition "${namespace}" "${resource}" "${cond_type}" "${expected}"; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      return 1
    fi
    sleep 2
  done
}

check_cnpg_operator() {
  if kubectl -n cnpg-system get deployment -l app.kubernetes.io/name=cloudnative-pg -o name 2>/dev/null | grep -q '^deployment.apps/'; then
    if kubectl -n cnpg-system wait --for=condition=Available deployment -l app.kubernetes.io/name=cloudnative-pg --timeout=30s >/dev/null 2>&1; then
      record_check "cnpg_operator_available" "PASS" "cloudnative-pg deployment Available in cnpg-system"
      return 0
    fi
    record_check "cnpg_operator_available" "FAIL" "cloudnative-pg deployment found but not Available"
    return 1
  fi

  record_check "cnpg_operator_available" "FAIL" "cloudnative-pg deployment not found in cnpg-system"
  return 1
}

check_cnpg_cluster_ready() {
  if wait_for_condition "${NAMESPACE}" "cluster.postgresql.cnpg.io/epydios-postgres" "Ready" "True"; then
    record_check "cnpg_cluster_ready" "PASS" "epydios-postgres Ready=True"
    return 0
  fi

  local status
  status="$(kubectl -n "${NAMESPACE}" get cluster.postgresql.cnpg.io epydios-postgres -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true)"
  if [ -z "${status}" ]; then
    status="cluster not found or no status.conditions"
  fi
  record_check "cnpg_cluster_ready" "FAIL" "${status}"
  return 1
}

check_postgres_smoketest_job() {
  if wait_for_condition "${NAMESPACE}" "job.batch/epydios-postgres-smoketest" "Complete" "True"; then
    record_check "postgres_smoketest_job_complete" "PASS" "epydios-postgres-smoketest Complete=True"
    return 0
  fi

  local status
  status="$(kubectl -n "${NAMESPACE}" get job epydios-postgres-smoketest -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true)"
  if [ -z "${status}" ]; then
    status="job not found or no status.conditions"
  fi
  record_check "postgres_smoketest_job_complete" "FAIL" "${status}"
  return 1
}

check_provider_discovery() {
  local ok=0
  local statuses provider_id

  if wait_for_condition "${NAMESPACE}" "extensionprovider.controlplane.epydios.ai/oss-profile-static" "Ready" "True" &&
     wait_for_condition "${NAMESPACE}" "extensionprovider.controlplane.epydios.ai/oss-profile-static" "Probed" "True"; then
    ok=1
  fi

  statuses="$(
    kubectl -n "${NAMESPACE}" get extensionprovider oss-profile-static \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
  )"
  provider_id="$(
    kubectl -n "${NAMESPACE}" get extensionprovider oss-profile-static \
      -o jsonpath='{.status.resolved.providerId}' 2>/dev/null || true
  )"

  if [ "${ok}" -eq 1 ]; then
    record_check "provider_discovery_ready_probed" "PASS" "oss-profile-static Ready=True Probed=True providerId=${provider_id:-<empty>}"
    return 0
  fi

  if [ -z "${statuses}" ]; then
    statuses="extensionprovider not found or no status.conditions"
  fi
  record_check "provider_discovery_ready_probed" "FAIL" "${statuses} providerId=${provider_id:-<empty>}"
  return 1
}

print_summary() {
  local overall="PASS"
  local bootstrap_marker

  if [ "${BOOTSTRAP_STATUS}" = "FAIL" ]; then
    overall="FAIL"
  fi

  for pair in "${check_results[@]}"; do
    local name status
    name="${pair%%:*}"
    status="${pair##*:}"
    if [ "${status}" != "PASS" ]; then
      overall="FAIL"
    fi
  done

  echo
  echo "M0 Verification Summary (${RUNTIME}, cluster=${CLUSTER_NAME})"
  echo "------------------------------------------------------------"
  bootstrap_marker="${BOOTSTRAP_STATUS}"
  printf '%-38s %s\n' "bootstrap_with_system_smoketest" "${bootstrap_marker}"

  local i pair name status detail
  for i in "${!check_results[@]}"; do
    pair="${check_results[$i]}"
    name="${pair%%:*}"
    status="${pair##*:}"
    detail="${check_details[$i]#*:}"
    printf '%-38s %s\n' "${name}" "${status}"
    printf '  %s\n' "${detail}"
  done

  echo "------------------------------------------------------------"
  printf '%-38s %s\n' "overall" "${overall}"

  if [ "${overall}" != "PASS" ]; then
    return 1
  fi
  return 0
}

main() {
  require_cmd kubectl
  if [ "${RUN_BOOTSTRAP}" = "1" ]; then
    require_cmd helm
    require_cmd docker
    if [ "${RUNTIME}" = "kind" ]; then
      require_cmd kind
    elif [ "${RUNTIME}" = "k3d" ]; then
      require_cmd k3d
    fi
  fi

  run_bootstrap

  check_cnpg_operator || true
  check_cnpg_cluster_ready || true
  check_postgres_smoketest_job || true
  check_provider_discovery || true

  print_summary
}

main "$@"

