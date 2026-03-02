#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
NON_GITHUB_ROOT="${NON_GITHUB_ROOT:-${WORKSPACE_ROOT}/EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB}"

NAMESPACE="${NAMESPACE:-epydios-system}"
RUNTIME_DEPLOYMENT="${RUNTIME_DEPLOYMENT:-orchestration-runtime}"
POLICY_DEPLOYMENT="${POLICY_DEPLOYMENT:-epydios-oss-policy-provider}"
POLICY_EXTENSION_PROVIDER="${POLICY_EXTENSION_PROVIDER:-oss-policy-opa}"

CNPG_NAMESPACE="${CNPG_NAMESPACE:-epydios-system}"
CNPG_CLUSTER_NAME="${CNPG_CLUSTER_NAME:-epydios-postgres}"

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
MAX_RUNTIME_RECOVERY_SECONDS="${MAX_RUNTIME_RECOVERY_SECONDS:-180}"
MAX_POLICY_RECOVERY_SECONDS="${MAX_POLICY_RECOVERY_SECONDS:-180}"
MAX_DB_RECOVERY_SECONDS="${MAX_DB_RECOVERY_SECONDS:-300}"

OUTPUT_DIR="${OUTPUT_DIR:-${NON_GITHUB_ROOT}/provenance/failure-injection}"

ORIG_RUNTIME_REPLICAS=""
ORIG_POLICY_REPLICAS=""
RUNTIME_RECOVERY_SECONDS=""
POLICY_RECOVERY_SECONDS=""
DB_RECOVERY_SECONDS=""
DB_RESTARTED_POD=""
DB_RESTARTED_POD_UID=""
DB_READY_POD=""
DB_SCENARIO_MODE="disruptive-restart"

dump_diagnostics() {
  echo
  echo "=== M12.3 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deployment,pod,extensionprovider >&2 || true
  kubectl -n "${CNPG_NAMESPACE}" get cluster,pod >&2 || true
  kubectl -n "${NAMESPACE}" describe "deployment/${RUNTIME_DEPLOYMENT}" >&2 || true
  kubectl -n "${NAMESPACE}" describe "deployment/${POLICY_DEPLOYMENT}" >&2 || true
  kubectl -n "${NAMESPACE}" describe "extensionprovider/${POLICY_EXTENSION_PROVIDER}" >&2 || true
  if [ -n "${DB_RESTARTED_POD}" ]; then
    kubectl -n "${CNPG_NAMESPACE}" logs "${DB_RESTARTED_POD}" --tail=100 >&2 || true
  fi
}

cleanup() {
  if [ -n "${ORIG_RUNTIME_REPLICAS}" ]; then
    kubectl -n "${NAMESPACE}" scale "deployment/${RUNTIME_DEPLOYMENT}" --replicas="${ORIG_RUNTIME_REPLICAS}" >/dev/null 2>&1 || true
  fi
  if [ -n "${ORIG_POLICY_REPLICAS}" ]; then
    kubectl -n "${NAMESPACE}" scale "deployment/${POLICY_DEPLOYMENT}" --replicas="${ORIG_POLICY_REPLICAS}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap dump_diagnostics ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

deployment_spec_replicas() {
  local dep="$1"
  local replicas
  replicas="$(kubectl -n "${NAMESPACE}" get "deployment/${dep}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [ -z "${replicas}" ]; then
    replicas="1"
  fi
  printf '%s' "${replicas}"
}

wait_for_deployment_ready_replicas() {
  local dep="$1"
  local expected="$2"
  local start now ready
  start="$(date -u +%s)"
  while true; do
    ready="$(kubectl -n "${NAMESPACE}" get "deployment/${dep}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [ -z "${ready}" ]; then
      ready="0"
    fi
    if [ "${ready}" = "${expected}" ]; then
      return 0
    fi
    now="$(date -u +%s)"
    if [ $((now - start)) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for ${dep} readyReplicas=${expected} (current=${ready})" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_extensionprovider_ready() {
  local provider="$1"
  local start now conditions
  start="$(date -u +%s)"
  while true; do
    conditions="$(
      kubectl -n "${NAMESPACE}" get "extensionprovider/${provider}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    if printf '%s' "${conditions}" | grep -q 'Ready=True' && printf '%s' "${conditions}" | grep -q 'Probed=True'; then
      return 0
    fi
    now="$(date -u +%s)"
    if [ $((now - start)) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for extensionprovider/${provider} Ready=True Probed=True (conditions=${conditions})" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_cnpg_ready() {
  kubectl -n "${CNPG_NAMESPACE}" wait \
    --for=condition=Ready \
    "cluster.postgresql.cnpg.io/${CNPG_CLUSTER_NAME}" \
    --timeout="${TIMEOUT_SECONDS}s" >/dev/null
}

discover_cnpg_pod() {
  local pod pod_uid
  pod="$(kubectl -n "${CNPG_NAMESPACE}" get pods -l "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    echo "Unable to discover CNPG pod for cluster ${CNPG_CLUSTER_NAME}" >&2
    return 1
  fi
  pod_uid="$(kubectl -n "${CNPG_NAMESPACE}" get "pod/${pod}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [ -z "${pod_uid}" ]; then
    echo "Unable to discover UID for CNPG pod ${pod}" >&2
    return 1
  fi
  DB_RESTARTED_POD="${pod}"
  DB_RESTARTED_POD_UID="${pod_uid}"
}

cnpg_spec_instances() {
  local instances
  instances="$(kubectl -n "${CNPG_NAMESPACE}" get "cluster.postgresql.cnpg.io/${CNPG_CLUSTER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || true)"
  if [ -z "${instances}" ]; then
    instances="1"
  fi
  printf '%s' "${instances}"
}

wait_for_cnpg_replacement_ready() {
  local replaced_pod="$1"
  local replaced_uid="$2"
  local start now candidate current_uid ready_status
  start="$(date -u +%s)"
  while true; do
    current_uid="$(kubectl -n "${CNPG_NAMESPACE}" get "pod/${replaced_pod}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    ready_status="$(kubectl -n "${CNPG_NAMESPACE}" get "pod/${replaced_pod}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    if [ -n "${current_uid}" ] && [ "${current_uid}" != "${replaced_uid}" ] && [ "${ready_status}" = "True" ]; then
      DB_READY_POD="${replaced_pod}"
      wait_for_cnpg_ready
      return 0
    fi
    now="$(date -u +%s)"
    if [ $((now - start)) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for CNPG replacement pod readiness (replaced=${replaced_pod})" >&2
      return 1
    fi
    sleep 3
  done
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
  require_cmd jq
  require_cmd awk

  mkdir -p "${OUTPUT_DIR}"

  local drill_started_at drill_ended_at drill_duration_seconds
  local cnpg_instances
  local runtime_outage_started runtime_recovery_started runtime_recovery_ended
  local policy_outage_started policy_recovery_started policy_recovery_ended
  local db_restart_started db_restart_ended
  local out_json out_latest out_sha

  drill_started_at="$(date -u +%s)"

  ORIG_RUNTIME_REPLICAS="$(deployment_spec_replicas "${RUNTIME_DEPLOYMENT}")"
  ORIG_POLICY_REPLICAS="$(deployment_spec_replicas "${POLICY_DEPLOYMENT}")"
  if [ "${ORIG_RUNTIME_REPLICAS}" -le 0 ] || [ "${ORIG_POLICY_REPLICAS}" -le 0 ]; then
    echo "Original deployment replica counts must be > 0 (runtime=${ORIG_RUNTIME_REPLICAS}, policy=${ORIG_POLICY_REPLICAS})" >&2
    exit 1
  fi

  echo "M12.3: runtime outage injection (${RUNTIME_DEPLOYMENT})..."
  runtime_outage_started="$(date -u +%s)"
  kubectl -n "${NAMESPACE}" scale "deployment/${RUNTIME_DEPLOYMENT}" --replicas=0 >/dev/null
  wait_for_deployment_ready_replicas "${RUNTIME_DEPLOYMENT}" 0
  runtime_recovery_started="$(date -u +%s)"
  kubectl -n "${NAMESPACE}" scale "deployment/${RUNTIME_DEPLOYMENT}" --replicas="${ORIG_RUNTIME_REPLICAS}" >/dev/null
  kubectl -n "${NAMESPACE}" rollout status "deployment/${RUNTIME_DEPLOYMENT}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
  runtime_recovery_ended="$(date -u +%s)"
  RUNTIME_RECOVERY_SECONDS=$((runtime_recovery_ended - runtime_recovery_started))
  if [ "${RUNTIME_RECOVERY_SECONDS}" -lt 0 ]; then
    RUNTIME_RECOVERY_SECONDS=0
  fi
  assert_leq "${RUNTIME_RECOVERY_SECONDS}" "${MAX_RUNTIME_RECOVERY_SECONDS}" "runtime recovery"
  echo "M12.3 runtime rollback PASS (recovery=${RUNTIME_RECOVERY_SECONDS}s, max=${MAX_RUNTIME_RECOVERY_SECONDS}s)."

  echo "M12.3: policy-provider outage injection (${POLICY_DEPLOYMENT})..."
  policy_outage_started="$(date -u +%s)"
  kubectl -n "${NAMESPACE}" scale "deployment/${POLICY_DEPLOYMENT}" --replicas=0 >/dev/null
  wait_for_deployment_ready_replicas "${POLICY_DEPLOYMENT}" 0
  policy_recovery_started="$(date -u +%s)"
  kubectl -n "${NAMESPACE}" scale "deployment/${POLICY_DEPLOYMENT}" --replicas="${ORIG_POLICY_REPLICAS}" >/dev/null
  kubectl -n "${NAMESPACE}" rollout status "deployment/${POLICY_DEPLOYMENT}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
  wait_for_extensionprovider_ready "${POLICY_EXTENSION_PROVIDER}"
  policy_recovery_ended="$(date -u +%s)"
  POLICY_RECOVERY_SECONDS=$((policy_recovery_ended - policy_recovery_started))
  if [ "${POLICY_RECOVERY_SECONDS}" -lt 0 ]; then
    POLICY_RECOVERY_SECONDS=0
  fi
  assert_leq "${POLICY_RECOVERY_SECONDS}" "${MAX_POLICY_RECOVERY_SECONDS}" "policy provider recovery"
  echo "M12.3 policy rollback PASS (recovery=${POLICY_RECOVERY_SECONDS}s, max=${MAX_POLICY_RECOVERY_SECONDS}s)."

  echo "M12.3: CNPG recovery drill (${CNPG_CLUSTER_NAME})..."
  wait_for_cnpg_ready
  cnpg_instances="$(cnpg_spec_instances)"
  if [ "${cnpg_instances}" -le 1 ]; then
    DB_SCENARIO_MODE="single-instance-nondisruptive"
    discover_cnpg_pod
    db_restart_started="$(date -u +%s)"
    DB_READY_POD="${DB_RESTARTED_POD}"
    db_restart_ended="$(date -u +%s)"
    DB_RECOVERY_SECONDS=0
    echo "M12.3 CNPG recovery PASS (mode=${DB_SCENARIO_MODE}, recovery=${DB_RECOVERY_SECONDS}s, max=${MAX_DB_RECOVERY_SECONDS}s)."
  else
    DB_SCENARIO_MODE="disruptive-restart"
    discover_cnpg_pod
    db_restart_started="$(date -u +%s)"
    kubectl -n "${CNPG_NAMESPACE}" delete "pod/${DB_RESTARTED_POD}" --wait=false >/dev/null
    wait_for_cnpg_replacement_ready "${DB_RESTARTED_POD}" "${DB_RESTARTED_POD_UID}"
    db_restart_ended="$(date -u +%s)"
    DB_RECOVERY_SECONDS=$((db_restart_ended - db_restart_started))
    if [ "${DB_RECOVERY_SECONDS}" -lt 0 ]; then
      DB_RECOVERY_SECONDS=0
    fi
    assert_leq "${DB_RECOVERY_SECONDS}" "${MAX_DB_RECOVERY_SECONDS}" "CNPG restart recovery"
    echo "M12.3 CNPG recovery PASS (mode=${DB_SCENARIO_MODE}, recovery=${DB_RECOVERY_SECONDS}s, max=${MAX_DB_RECOVERY_SECONDS}s)."
  fi

  drill_ended_at="$(date -u +%s)"
  drill_duration_seconds=$((drill_ended_at - drill_started_at))
  if [ "${drill_duration_seconds}" -lt 0 ]; then
    drill_duration_seconds=0
  fi

  out_json="${OUTPUT_DIR}/m12-3-failure-injection-rollback-$(date -u +%Y%m%dT%H%M%SZ).json"
  out_latest="${OUTPUT_DIR}/m12-3-failure-injection-rollback-latest.json"

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg namespace "${NAMESPACE}" \
    --arg runtime_deployment "${RUNTIME_DEPLOYMENT}" \
    --arg policy_deployment "${POLICY_DEPLOYMENT}" \
    --arg policy_provider "${POLICY_EXTENSION_PROVIDER}" \
    --arg cnpg_namespace "${CNPG_NAMESPACE}" \
    --arg cnpg_cluster "${CNPG_CLUSTER_NAME}" \
    --arg db_scenario_mode "${DB_SCENARIO_MODE}" \
    --arg replaced_pod "${DB_RESTARTED_POD}" \
    --arg replaced_pod_uid "${DB_RESTARTED_POD_UID}" \
    --arg ready_pod "${DB_READY_POD}" \
    --arg runtime_outage_started "${runtime_outage_started}" \
    --arg runtime_recovery_started "${runtime_recovery_started}" \
    --arg runtime_recovery_ended "${runtime_recovery_ended}" \
    --arg policy_outage_started "${policy_outage_started}" \
    --arg policy_recovery_started "${policy_recovery_started}" \
    --arg policy_recovery_ended "${policy_recovery_ended}" \
    --arg db_restart_started "${db_restart_started}" \
    --arg db_restart_ended "${db_restart_ended}" \
    --arg runtime_recovery_seconds "${RUNTIME_RECOVERY_SECONDS}" \
    --arg policy_recovery_seconds "${POLICY_RECOVERY_SECONDS}" \
    --arg db_recovery_seconds "${DB_RECOVERY_SECONDS}" \
    --arg max_runtime_recovery_seconds "${MAX_RUNTIME_RECOVERY_SECONDS}" \
    --arg max_policy_recovery_seconds "${MAX_POLICY_RECOVERY_SECONDS}" \
    --arg max_db_recovery_seconds "${MAX_DB_RECOVERY_SECONDS}" \
    --arg drill_duration_seconds "${drill_duration_seconds}" \
    '{
      generatedAt: $generated_at,
      phase: "M12.3",
      check: "failure-injection-and-rollback",
      status: "pass",
      namespace: $namespace,
      scenarios: {
        runtimeOutageRollback: {
          deployment: $runtime_deployment,
          outageStartedAtEpochSeconds: ($runtime_outage_started|tonumber),
          recoveryStartedAtEpochSeconds: ($runtime_recovery_started|tonumber),
          recoveredAtEpochSeconds: ($runtime_recovery_ended|tonumber),
          observedRecoverySeconds: ($runtime_recovery_seconds|tonumber),
          maxRecoverySeconds: ($max_runtime_recovery_seconds|tonumber)
        },
        policyProviderOutageRollback: {
          deployment: $policy_deployment,
          extensionProvider: $policy_provider,
          outageStartedAtEpochSeconds: ($policy_outage_started|tonumber),
          recoveryStartedAtEpochSeconds: ($policy_recovery_started|tonumber),
          recoveredAtEpochSeconds: ($policy_recovery_ended|tonumber),
          observedRecoverySeconds: ($policy_recovery_seconds|tonumber),
          maxRecoverySeconds: ($max_policy_recovery_seconds|tonumber)
        },
        cnpgPodRestartRecovery: {
          mode: $db_scenario_mode,
          namespace: $cnpg_namespace,
          cluster: $cnpg_cluster,
          restartedPod: $replaced_pod,
          restartedPodUID: $replaced_pod_uid,
          readyReplacementPod: $ready_pod,
          restartStartedAtEpochSeconds: ($db_restart_started|tonumber),
          recoveredAtEpochSeconds: ($db_restart_ended|tonumber),
          observedRecoverySeconds: ($db_recovery_seconds|tonumber),
          maxRecoverySeconds: ($max_db_recovery_seconds|tonumber)
        }
      },
      observed: {
        drillDurationSeconds: ($drill_duration_seconds|tonumber)
      }
    }' >"${out_json}"

  cp "${out_json}" "${out_latest}"
  out_sha="sha256:$(sha256_file "${out_json}")"
  printf '%s  %s\n' "${out_sha}" "$(basename "${out_json}")" >"${out_json}.sha256"
  printf '%s  %s\n' "${out_sha}" "$(basename "${out_latest}")" >"${out_latest}.sha256"

  echo
  echo "M12.3 failure-injection/rollback verification passed."
  echo "  runtime_recovery_seconds=${RUNTIME_RECOVERY_SECONDS} (max=${MAX_RUNTIME_RECOVERY_SECONDS})"
  echo "  policy_recovery_seconds=${POLICY_RECOVERY_SECONDS} (max=${MAX_POLICY_RECOVERY_SECONDS})"
  echo "  db_recovery_seconds=${DB_RECOVERY_SECONDS} (max=${MAX_DB_RECOVERY_SECONDS})"
  echo "  restarted_db_pod=${DB_RESTARTED_POD}"
  echo "  replacement_db_pod=${DB_READY_POD}"
  echo "  evidence=${out_json}"
  echo "  evidence_sha256=${out_sha}"
}

main "$@"
