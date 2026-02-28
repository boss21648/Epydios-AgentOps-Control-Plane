#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"

RUN_BOOTSTRAP="${RUN_BOOTSTRAP:-1}"
RUN_IMAGE_PREP="${RUN_IMAGE_PREP:-1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
LOCAL_PORT="${LOCAL_PORT:-18084}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-15}"

OPA_SIDECAR_IMAGE="${OPA_SIDECAR_IMAGE:-openpolicyagent/opa:0.67.1}"

PORT_FORWARD_PID=""
TMPDIR_LOCAL="$(mktemp -d)"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== M5 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get extensionprovider,deploy,svc,pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/extension-provider-registry-controller >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/oss-profile-static-resolver >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/epydios-oss-policy-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/epydios-oss-evidence-provider >&2 || true

  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=orchestration-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    echo "--- logs pod/${pod} container=runtime ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --tail=200 >&2 || true
    echo "--- previous logs pod/${pod} container=runtime (if any) ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --previous --tail=200 >&2 || true
  fi
}

stop_port_forward() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  PORT_FORWARD_PID=""
}

cleanup() {
  stop_port_forward
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

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout=8m
}

wait_for_provider_ready_probed() {
  local provider="$1"
  local start
  start="$(date +%s)"
  while true; do
    local statuses
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    if printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider discovery status on ${provider}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

ensure_bootstrap_if_requested() {
  if [ "${RUN_BOOTSTRAP}" != "1" ]; then
    return 0
  fi

  echo "Ensuring M0 substrate (CNPG + Postgres smoke)..."
  case "${RUNTIME}" in
    kind)
      CLUSTER_NAME="${CLUSTER_NAME}" WITH_SYSTEM_SMOKETEST=0 "${SCRIPT_DIR}/bootstrap-kind.sh"
      ;;
    k3d)
      CLUSTER_NAME="${CLUSTER_NAME}" WITH_SYSTEM_SMOKETEST=0 "${SCRIPT_DIR}/bootstrap-k3d.sh"
      ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac
}

prepare_images_if_requested() {
  if [ "${RUN_IMAGE_PREP}" != "1" ]; then
    return 0
  fi

  echo "Building/loading local images for M5 runtime orchestration..."
  INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/build-local-images.sh"

  echo "Pulling OPA sidecar image for local cluster preload (${OPA_SIDECAR_IMAGE})..."
  if ! docker pull "${OPA_SIDECAR_IMAGE}"; then
    echo "Warning: failed to pull ${OPA_SIDECAR_IMAGE}; continuing (cluster may pull directly)." >&2
  fi

  case "${RUNTIME}" in
    kind)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-kind.sh"
      if docker image inspect "${OPA_SIDECAR_IMAGE}" >/dev/null 2>&1; then
        kind load docker-image --name "${CLUSTER_NAME}" "${OPA_SIDECAR_IMAGE}"
      fi
      ;;
    k3d)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-k3d.sh"
      if docker image inspect "${OPA_SIDECAR_IMAGE}" >/dev/null 2>&1; then
        k3d image import --cluster "${CLUSTER_NAME}" "${OPA_SIDECAR_IMAGE}"
      fi
      ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac
}

apply_runtime_dependencies() {
  echo "Applying runtime + provider manifests..."
  kubectl apply -k "${REPO_ROOT}/platform/system"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-policy-opa"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-evidence-memory"

  wait_for_deployment extension-provider-registry-controller
  wait_for_deployment orchestration-runtime
  wait_for_deployment oss-profile-static-resolver
  wait_for_deployment epydios-oss-policy-provider
  wait_for_deployment epydios-oss-evidence-provider

  wait_for_provider_ready_probed oss-profile-static
  wait_for_provider_ready_probed oss-policy-opa
  wait_for_provider_ready_probed oss-evidence-memory
}

start_port_forward() {
  kubectl -n "${NAMESPACE}" port-forward svc/orchestration-runtime "${LOCAL_PORT}:8080" >"${TMPDIR_LOCAL}/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!

  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "${CURL_TIMEOUT_ARGS[@]}" "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for runtime port-forward to become ready" >&2
      cat "${TMPDIR_LOCAL}/port-forward.log" >&2 || true
      return 1
    fi
    sleep 1
  done
}

write_requests() {
  cat >"${TMPDIR_LOCAL}/allow.json" <<'JSON'
{
  "meta": {
    "requestId": "m5-allow-001",
    "timestamp": "2026-02-27T00:00:00Z",
    "tenantId": "demo-tenant",
    "projectId": "mlops-dev",
    "environment": "dev"
  },
  "subject": {
    "type": "user",
    "id": "alice"
  },
  "action": {
    "verb": "read",
    "target": "inference"
  },
  "task": {
    "kind": "inference",
    "sensitivity": "standard"
  },
  "resource": {
    "kind": "InferenceService",
    "namespace": "kserve-smoke",
    "name": "python-smoke"
  },
  "mode": "enforce"
}
JSON

  cat >"${TMPDIR_LOCAL}/deny.json" <<'JSON'
{
  "meta": {
    "requestId": "m5-deny-001",
    "timestamp": "2026-02-27T00:00:00Z",
    "tenantId": "regulated-tenant",
    "projectId": "regulated-project",
    "environment": "prod"
  },
  "subject": {
    "type": "user",
    "id": "bob",
    "attributes": {
      "approvedForProd": false
    }
  },
  "action": {
    "verb": "delete",
    "target": "inference"
  },
  "task": {
    "kind": "inference",
    "sensitivity": "high"
  },
  "resource": {
    "kind": "InferenceService",
    "namespace": "kserve-smoke",
    "name": "python-smoke"
  },
  "mode": "enforce"
}
JSON
}

post_json() {
  local path="$1"
  local body_file="$2"
  local out_file="$3"
  curl -fsS "${CURL_TIMEOUT_ARGS[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    "http://127.0.0.1:${LOCAL_PORT}${path}" \
    --data-binary @"${body_file}" \
    >"${out_file}"
}

get_json() {
  local path="$1"
  local out_file="$2"
  curl -fsS "${CURL_TIMEOUT_ARGS[@]}" "http://127.0.0.1:${LOCAL_PORT}${path}" >"${out_file}"
}

assert_response_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "${pattern}" "${file}"; then
    echo "Assertion failed for ${label}: pattern ${pattern} not found" >&2
    cat "${file}" >&2
    return 1
  fi
}

extract_json_string() {
  local file="$1"
  local field="$2"
  grep -Eo "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "${file}" | head -n 1 | sed -E "s/.*:[[:space:]]*\"([^\"]+)\"/\\1/"
}

run_runtime_smoke() {
  write_requests
  start_port_forward

  post_json "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/allow.json" "${TMPDIR_LOCAL}/allow-run.json"
  post_json "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/deny.json" "${TMPDIR_LOCAL}/deny-run.json"

  assert_response_contains "${TMPDIR_LOCAL}/allow-run.json" '"status"[[:space:]]*:[[:space:]]*"COMPLETED"' "allow run completion"
  assert_response_contains "${TMPDIR_LOCAL}/allow-run.json" '"policyDecision"[[:space:]]*:[[:space:]]*"ALLOW"' "allow run decision"
  assert_response_contains "${TMPDIR_LOCAL}/allow-run.json" '"selectedProfileProvider"[[:space:]]*:[[:space:]]*"[^"]+"' "allow selected profile provider"
  assert_response_contains "${TMPDIR_LOCAL}/allow-run.json" '"selectedPolicyProvider"[[:space:]]*:[[:space:]]*"[^"]+"' "allow selected policy provider"
  assert_response_contains "${TMPDIR_LOCAL}/allow-run.json" '"selectedEvidenceProvider"[[:space:]]*:[[:space:]]*"[^"]+"' "allow selected evidence provider"

  assert_response_contains "${TMPDIR_LOCAL}/deny-run.json" '"status"[[:space:]]*:[[:space:]]*"COMPLETED"' "deny run completion"
  assert_response_contains "${TMPDIR_LOCAL}/deny-run.json" '"policyDecision"[[:space:]]*:[[:space:]]*"DENY"' "deny run decision"

  local allow_run_id deny_run_id
  allow_run_id="$(extract_json_string "${TMPDIR_LOCAL}/allow-run.json" "runId")"
  deny_run_id="$(extract_json_string "${TMPDIR_LOCAL}/deny-run.json" "runId")"
  if [ -z "${allow_run_id}" ] || [ -z "${deny_run_id}" ]; then
    echo "Failed to extract runId values from runtime run responses" >&2
    cat "${TMPDIR_LOCAL}/allow-run.json" >&2
    cat "${TMPDIR_LOCAL}/deny-run.json" >&2
    return 1
  fi

  get_json "/v1alpha1/runtime/runs/${allow_run_id}" "${TMPDIR_LOCAL}/allow-get.json"
  get_json "/v1alpha1/runtime/runs/${deny_run_id}" "${TMPDIR_LOCAL}/deny-get.json"
  get_json "/v1alpha1/runtime/runs?limit=10" "${TMPDIR_LOCAL}/list-runs.json"

  assert_response_contains "${TMPDIR_LOCAL}/allow-get.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${allow_run_id}\"" "allow get runId"
  assert_response_contains "${TMPDIR_LOCAL}/allow-get.json" '"status"[[:space:]]*:[[:space:]]*"COMPLETED"' "allow get status"
  assert_response_contains "${TMPDIR_LOCAL}/deny-get.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${deny_run_id}\"" "deny get runId"
  assert_response_contains "${TMPDIR_LOCAL}/deny-get.json" '"policyDecision"[[:space:]]*:[[:space:]]*"DENY"' "deny get decision"
  assert_response_contains "${TMPDIR_LOCAL}/list-runs.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${allow_run_id}\"" "list includes allow run"
  assert_response_contains "${TMPDIR_LOCAL}/list-runs.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${deny_run_id}\"" "list includes deny run"
  assert_response_contains "${TMPDIR_LOCAL}/list-runs.json" '"count"[[:space:]]*:[[:space:]]*[1-9][0-9]*' "list count"
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd docker

  case "${RUNTIME}" in
    kind) require_cmd kind ;;
    k3d) require_cmd k3d ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac

  if [ "${RUN_BOOTSTRAP}" = "1" ]; then
    require_cmd helm
  fi

  ensure_bootstrap_if_requested
  prepare_images_if_requested
  apply_runtime_dependencies
  run_runtime_smoke

  echo "M5 runtime orchestration smoke passed (create/list/get + ALLOW/DENY execution)."
}

main "$@"
