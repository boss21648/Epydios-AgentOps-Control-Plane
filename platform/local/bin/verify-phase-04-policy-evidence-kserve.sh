#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-360}"

RUN_PHASE_03="${RUN_PHASE_03:-0}"
RUN_PHASE_02="${RUN_PHASE_02:-0}"
RUN_IMAGE_PREP="${RUN_IMAGE_PREP:-1}"
RUN_KSERVE_SMOKE="${RUN_KSERVE_SMOKE:-1}"
RUN_SECURE_AUTH_PATH="${RUN_SECURE_AUTH_PATH:-1}"
FORCE_CONFLICTS="${FORCE_CONFLICTS:-1}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-1}"
AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-1}"

CLEANUP_SECURE_FIXTURES="${CLEANUP_SECURE_FIXTURES:-1}"
SECURE_TOKEN_VALUE="${SECURE_TOKEN_VALUE:-epydios-local-mtls-token}"
SECURE_POLICY_MIN_PRIORITY="${SECURE_POLICY_MIN_PRIORITY:-200}"
SECURE_EVIDENCE_MIN_PRIORITY="${SECURE_EVIDENCE_MIN_PRIORITY:-200}"

OPA_SIDECAR_IMAGE="${OPA_SIDECAR_IMAGE:-openpolicyagent/opa:0.67.1}"

KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-kserve-smoke}"
KSERVE_ISVC_NAME="${KSERVE_ISVC_NAME:-python-smoke}"
KSERVE_MODEL_NAME="${KSERVE_MODEL_NAME:-python-smoke}"
KSERVE_LOCAL_PORT="${KSERVE_LOCAL_PORT:-18080}"
POLICY_LOCAL_PORT="${POLICY_LOCAL_PORT:-18082}"
EVIDENCE_LOCAL_PORT="${EVIDENCE_LOCAL_PORT:-18083}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-15}"

PORT_FORWARD_PID=""
TMPDIR_LOCAL="$(mktemp -d)"

CURRENT_BASE_URL=""
CURRENT_SCHEME=""
CURRENT_HEALTH_PATH=""
CURRENT_RESOLVE_HOST=""
CURRENT_AUTH_MODE="None"
declare -a CURRENT_CURL_AUTH_ARGS
CURRENT_CURL_AUTH_ARGS=()
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== Phase 04 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get extensionprovider,deploy,svc,pods >&2 || true
  kubectl -n "${KSERVE_NAMESPACE}" get inferenceservice,deploy,svc,pods >&2 || true
}

cleanup_secure_fixtures() {
  if [ "${RUN_SECURE_AUTH_PATH}" != "1" ] || [ "${CLEANUP_SECURE_FIXTURES}" != "1" ]; then
    return 0
  fi

  kubectl delete -k "${REPO_ROOT}/platform/tests/phase4-secure-mtls" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -k "${REPO_ROOT}/platform/tests/provider-discovery-mtls" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete secret \
    epydios-controller-mtls-client \
    epydios-provider-ca \
    mtls-provider-server-tls \
    mtls-bearer-client-token \
    mtls-bearer-provider-token \
    --ignore-not-found >/dev/null 2>&1 || true
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
  cleanup_secure_fixtures
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

secret_data_b64() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" -o "go-template={{index .data \"${key}\"}}" 2>/dev/null || true
}

read_secret_key_to_file() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local out_file="$4"
  local b64

  b64="$(secret_data_b64 "${namespace}" "${secret_name}" "${key}")"
  if [ -z "${b64}" ]; then
    echo "Missing secret data key: ${namespace}/${secret_name} key=${key}" >&2
    return 1
  fi

  printf '%s' "${b64}" | b64decode_stdin >"${out_file}"
}

read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local b64

  b64="$(secret_data_b64 "${namespace}" "${secret_name}" "${key}")"
  if [ -z "${b64}" ]; then
    echo "Missing secret data key: ${namespace}/${secret_name} key=${key}" >&2
    return 1
  fi

  printf '%s' "${b64}" | b64decode_stdin
}

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout=8m
}

provider_ready_probed() {
  local provider="$1"
  local statuses
  statuses="$(
    kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
  )"
  printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'
}

wait_for_provider_ready_probed() {
  local provider="$1"
  local start
  start="$(date +%s)"
  while true; do
    if provider_ready_probed "${provider}"; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider status Ready=True/Probed=True on ${provider}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

prepare_images() {
  if [ "${RUN_IMAGE_PREP}" != "1" ]; then
    return 0
  fi

  local include_mtls_provider="0"
  if [ "${RUN_SECURE_AUTH_PATH}" = "1" ]; then
    include_mtls_provider="1"
  fi

  echo "Building/loading local images for Phase 04..."
  INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER="${include_mtls_provider}" \
    "${SCRIPT_DIR}/build-local-images.sh"

  echo "Pulling OPA sidecar image for local preload (${OPA_SIDECAR_IMAGE})..."
  if ! docker pull "${OPA_SIDECAR_IMAGE}"; then
    echo "Warning: failed to pull ${OPA_SIDECAR_IMAGE}; continuing (cluster may pull it directly)." >&2
  fi

  case "${RUNTIME}" in
    kind)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER="${include_mtls_provider}" \
        "${SCRIPT_DIR}/load-local-images-kind.sh"
      if docker image inspect "${OPA_SIDECAR_IMAGE}" >/dev/null 2>&1; then
        kind load docker-image --name "${CLUSTER_NAME}" "${OPA_SIDECAR_IMAGE}"
      fi
      ;;
    k3d)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER="${include_mtls_provider}" \
        "${SCRIPT_DIR}/load-local-images-k3d.sh"
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

run_phase03_if_requested() {
  if [ "${RUN_PHASE_03}" != "1" ]; then
    return 0
  fi
  echo "Running Phase 03 verification first..."
  RUN_PHASE_02="${RUN_PHASE_02}" \
  RUN_FUNCTIONAL_SMOKE=1 \
  USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
  AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
  FORCE_CONFLICTS="${FORCE_CONFLICTS}" \
    "${SCRIPT_DIR}/verify-phase-03-kserve.sh"
}

apply_phase04_components() {
  echo "Applying system + policy + evidence provider components..."
  kubectl apply -k "${REPO_ROOT}/platform/system"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-policy-opa"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-evidence-memory"

  wait_for_deployment extension-provider-registry-controller
  wait_for_deployment oss-profile-static-resolver
  wait_for_deployment epydios-oss-policy-provider
  wait_for_deployment epydios-oss-evidence-provider

  wait_for_provider_ready_probed oss-profile-static
  wait_for_provider_ready_probed oss-policy-opa
  wait_for_provider_ready_probed oss-evidence-memory
}

apply_secure_auth_fixtures() {
  if [ "${RUN_SECURE_AUTH_PATH}" != "1" ]; then
    return 0
  fi

  echo "Applying secure-auth fixture providers (MTLS + MTLSAndBearerTokenSecret)..."
  KEEP_RESOURCES=1 NAMESPACE="${NAMESPACE}" TOKEN_VALUE="${SECURE_TOKEN_VALUE}" \
    "${SCRIPT_DIR}/smoke-provider-discovery-mtls.sh"

  kubectl apply -k "${REPO_ROOT}/platform/tests/phase4-secure-mtls"

  wait_for_deployment phase4-mtls-policy-provider
  wait_for_deployment phase4-mtls-bearer-evidence-provider

  wait_for_provider_ready_probed phase4-mtls-policy
  wait_for_provider_ready_probed phase4-mtls-bearer-evidence
}

select_provider() {
  local provider_type="$1"
  local min_priority="$2"
  local providers best_name best_priority
  providers="$(kubectl -n "${NAMESPACE}" get extensionprovider -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  best_name=""
  best_priority=-2147483648

  while IFS= read -r name; do
    local ptype enabled priority
    [ -n "${name}" ] || continue

    ptype="$(kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o jsonpath='{.spec.providerType}' 2>/dev/null || true)"
    [ "${ptype}" = "${provider_type}" ] || continue

    enabled="$(kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o jsonpath='{.spec.selection.enabled}' 2>/dev/null || true)"
    if [ -z "${enabled}" ]; then
      enabled="true"
    fi
    [ "${enabled}" = "true" ] || continue

    if ! provider_ready_probed "${name}"; then
      continue
    fi

    priority="$(kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o jsonpath='{.spec.selection.priority}' 2>/dev/null || true)"
    if [ -z "${priority}" ]; then
      priority=100
    fi

    if [ "${priority}" -lt "${min_priority}" ]; then
      continue
    fi

    if [ "${priority}" -gt "${best_priority}" ] || \
      { [ "${priority}" -eq "${best_priority}" ] && { [ -z "${best_name}" ] || [[ "${name}" < "${best_name}" ]]; }; }; then
      best_name="${name}"
      best_priority="${priority}"
    fi
  done <<<"${providers}"

  if [ -z "${best_name}" ]; then
    echo "No selectable ready provider found for providerType=${provider_type} minPriority=${min_priority}" >&2
    kubectl -n "${NAMESPACE}" get extensionprovider -o yaml >&2 || true
    return 1
  fi

  printf '%s' "${best_name}"
}

load_provider_auth_materials() {
  local provider="$1"
  local bearer_secret bearer_key client_tls_secret ca_secret token
  local client_cert_file client_key_file ca_file

  CURRENT_CURL_AUTH_ARGS=()

  CURRENT_AUTH_MODE="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.mode}' 2>/dev/null || true)"
  if [ -z "${CURRENT_AUTH_MODE}" ]; then
    CURRENT_AUTH_MODE="None"
  fi

  case "${CURRENT_AUTH_MODE}" in
    None)
      ;;
    BearerTokenSecret)
      bearer_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.name}' 2>/dev/null || true)"
      bearer_key="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.key}' 2>/dev/null || true)"
      if [ -z "${bearer_key}" ]; then
        bearer_key="token"
      fi
      if [ -z "${bearer_secret}" ]; then
        echo "Provider ${provider} auth.mode=${CURRENT_AUTH_MODE} missing bearerTokenSecretRef.name" >&2
        return 1
      fi
      token="$(read_secret_key "${NAMESPACE}" "${bearer_secret}" "${bearer_key}")"
      CURRENT_CURL_AUTH_ARGS+=(-H "Authorization: Bearer ${token}")
      ;;
    MTLS)
      client_tls_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.clientTLSSecretRef.name}' 2>/dev/null || true)"
      ca_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.caSecretRef.name}' 2>/dev/null || true)"
      if [ -z "${client_tls_secret}" ] || [ -z "${ca_secret}" ]; then
        echo "Provider ${provider} auth.mode=${CURRENT_AUTH_MODE} missing mTLS secret refs" >&2
        return 1
      fi
      client_cert_file="${TMPDIR_LOCAL}/${provider}-client.crt"
      client_key_file="${TMPDIR_LOCAL}/${provider}-client.key"
      ca_file="${TMPDIR_LOCAL}/${provider}-ca.crt"
      read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.crt" "${client_cert_file}"
      read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.key" "${client_key_file}"
      read_secret_key_to_file "${NAMESPACE}" "${ca_secret}" "ca.crt" "${ca_file}"
      CURRENT_CURL_AUTH_ARGS+=(--cert "${client_cert_file}" --key "${client_key_file}" --cacert "${ca_file}")
      ;;
    MTLSAndBearerTokenSecret)
      client_tls_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.clientTLSSecretRef.name}' 2>/dev/null || true)"
      ca_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.caSecretRef.name}' 2>/dev/null || true)"
      bearer_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.name}' 2>/dev/null || true)"
      bearer_key="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.key}' 2>/dev/null || true)"
      if [ -z "${bearer_key}" ]; then
        bearer_key="token"
      fi
      if [ -z "${client_tls_secret}" ] || [ -z "${ca_secret}" ] || [ -z "${bearer_secret}" ]; then
        echo "Provider ${provider} auth.mode=${CURRENT_AUTH_MODE} missing required secret refs" >&2
        return 1
      fi
      client_cert_file="${TMPDIR_LOCAL}/${provider}-client.crt"
      client_key_file="${TMPDIR_LOCAL}/${provider}-client.key"
      ca_file="${TMPDIR_LOCAL}/${provider}-ca.crt"
      read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.crt" "${client_cert_file}"
      read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.key" "${client_key_file}"
      read_secret_key_to_file "${NAMESPACE}" "${ca_secret}" "ca.crt" "${ca_file}"
      token="$(read_secret_key "${NAMESPACE}" "${bearer_secret}" "${bearer_key}")"
      CURRENT_CURL_AUTH_ARGS+=(--cert "${client_cert_file}" --key "${client_key_file}" --cacert "${ca_file}")
      CURRENT_CURL_AUTH_ARGS+=(-H "Authorization: Bearer ${token}")
      ;;
    *)
      echo "Unsupported auth.mode for local flow: ${CURRENT_AUTH_MODE} (provider=${provider})" >&2
      return 1
      ;;
  esac
}

start_port_forward_for_provider() {
  local provider="$1"
  local local_port="$2"

  local endpoint_url health_path scheme rest hostport host remote_port svc namespace
  endpoint_url="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.endpoint.url}')"
  health_path="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.endpoint.healthPath}' 2>/dev/null || true)"

  if [ -z "${health_path}" ]; then
    health_path="/healthz"
  fi

  scheme="${endpoint_url%%://*}"
  rest="${endpoint_url#*://}"
  hostport="${rest%%/*}"
  host="${hostport%%:*}"
  if [ "${host}" = "${hostport}" ]; then
    if [ "${scheme}" = "https" ]; then
      remote_port=443
    else
      remote_port=80
    fi
  else
    remote_port="${hostport##*:}"
  fi

  svc="${host%%.*}"
  namespace="$(printf '%s' "${host}" | cut -d. -f2)"
  if [ -z "${namespace}" ] || [ "${namespace}" = "svc" ] || [ "${namespace}" = "cluster" ] || [ "${namespace}" = "local" ]; then
    namespace="${NAMESPACE}"
  fi

  load_provider_auth_materials "${provider}"

  CURRENT_SCHEME="${scheme}"
  CURRENT_HEALTH_PATH="${health_path}"
  CURRENT_RESOLVE_HOST=""
  if [ "${CURRENT_SCHEME}" = "https" ]; then
    CURRENT_BASE_URL="https://${host}:${local_port}"
    CURRENT_RESOLVE_HOST="${host}:${local_port}:127.0.0.1"
  else
    CURRENT_BASE_URL="http://127.0.0.1:${local_port}"
  fi

  stop_port_forward
  kubectl -n "${namespace}" port-forward "svc/${svc}" "${local_port}:${remote_port}" >"${TMPDIR_LOCAL}/port-forward-${provider}.log" 2>&1 &
  PORT_FORWARD_PID=$!

  local start status out
  start="$(date +%s)"
  out="${TMPDIR_LOCAL}/health-${provider}.out.json"
  while true; do
    status="$(current_request GET "${CURRENT_HEALTH_PATH}" "" "${out}" 2>/dev/null || true)"
    if [[ "${status}" =~ ^2 ]]; then
      return 0
    fi

    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for provider health via port-forward: provider=${provider} localPort=${local_port}" >&2
      cat "${TMPDIR_LOCAL}/port-forward-${provider}.log" >&2 || true
      if [ -s "${out}" ]; then
        cat "${out}" >&2 || true
      fi
      return 1
    fi
    sleep 1
  done
}

current_request() {
  local method="$1"
  local path="$2"
  local body_file="$3"
  local out_file="$4"
  local url status

  url="${CURRENT_BASE_URL}${path}"

  if [ "${method}" = "POST" ]; then
    if [ "${#CURRENT_CURL_AUTH_ARGS[@]}" -gt 0 ]; then
      if [ -n "${CURRENT_RESOLVE_HOST}" ]; then
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' --resolve "${CURRENT_RESOLVE_HOST}" "${CURRENT_CURL_AUTH_ARGS[@]}" -H "Content-Type: application/json" -X POST "${url}" --data-binary @"${body_file}")"
      else
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' "${CURRENT_CURL_AUTH_ARGS[@]}" -H "Content-Type: application/json" -X POST "${url}" --data-binary @"${body_file}")"
      fi
    else
      if [ -n "${CURRENT_RESOLVE_HOST}" ]; then
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' --resolve "${CURRENT_RESOLVE_HOST}" -H "Content-Type: application/json" -X POST "${url}" --data-binary @"${body_file}")"
      else
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' -H "Content-Type: application/json" -X POST "${url}" --data-binary @"${body_file}")"
      fi
    fi
  else
    if [ "${#CURRENT_CURL_AUTH_ARGS[@]}" -gt 0 ]; then
      if [ -n "${CURRENT_RESOLVE_HOST}" ]; then
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' --resolve "${CURRENT_RESOLVE_HOST}" "${CURRENT_CURL_AUTH_ARGS[@]}" -X "${method}" "${url}")"
      else
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' "${CURRENT_CURL_AUTH_ARGS[@]}" -X "${method}" "${url}")"
      fi
    else
      if [ -n "${CURRENT_RESOLVE_HOST}" ]; then
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' --resolve "${CURRENT_RESOLVE_HOST}" -X "${method}" "${url}")"
      else
        status="$(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}")"
      fi
    fi
  fi

  printf '%s' "${status}"
}

current_post_json() {
  local path="$1"
  local body_file="$2"
  local out_file="$3"
  local status

  status="$(current_request POST "${path}" "${body_file}" "${out_file}")"
  case "${status}" in
    2??) ;;
    *)
      echo "POST failed: status=${status} url=${CURRENT_BASE_URL}${path} authMode=${CURRENT_AUTH_MODE}" >&2
      echo "request:" >&2
      cat "${body_file}" >&2 || true
      echo "response:" >&2
      cat "${out_file}" >&2 || true
      return 1
      ;;
  esac
}

capture_kserve_response() {
  if [ "${RUN_KSERVE_SMOKE}" != "1" ]; then
    printf '%s' '{"predictions":[]}'
    return 0
  fi

  local smoke_log response
  smoke_log="${TMPDIR_LOCAL}/kserve-smoke.log"

  NAMESPACE="${KSERVE_NAMESPACE}" \
  ISVC_NAME="${KSERVE_ISVC_NAME}" \
  MODEL_NAME="${KSERVE_MODEL_NAME}" \
  LOCAL_PORT="${KSERVE_LOCAL_PORT}" \
    "${SCRIPT_DIR}/smoke-kserve-inferenceservice.sh" | tee "${smoke_log}" >&2

  response="$(sed -En 's/^KServe functional smoke response \([^)]*\): (.*)$/\1/p' "${smoke_log}" | tail -1)"
  if [ -z "${response}" ]; then
    echo "Failed to parse KServe response from smoke output." >&2
    cat "${smoke_log}" >&2 || true
    return 1
  fi
  printf '%s' "${response}"
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
  local key="$2"
  grep -Eo "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "${file}" | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

run_policy_evidence_flow() {
  local flow_name="$1"
  local policy_min_priority="$2"
  local evidence_min_priority="$3"
  local require_secure_names="$4"
  local kserve_response_json="$5"
  local expected_decision="${6:-ALLOW}"

  local policy_provider evidence_provider
  local run_id now_ts evidence_id
  expected_decision="$(printf '%s' "${expected_decision}" | tr '[:lower:]' '[:upper:]')"
  if [ "${expected_decision}" != "ALLOW" ] && [ "${expected_decision}" != "DENY" ]; then
    echo "Unsupported expected decision for ${flow_name}: ${expected_decision} (expected ALLOW|DENY)" >&2
    return 1
  fi

  policy_provider="$(select_provider PolicyProvider "${policy_min_priority}")"
  evidence_provider="$(select_provider EvidenceProvider "${evidence_min_priority}")"

  if [ "${require_secure_names}" = "1" ]; then
    if [[ "${policy_provider}" != phase4-mtls-* ]]; then
      echo "Secure flow selected unexpected policy provider: ${policy_provider}" >&2
      return 1
    fi
    if [[ "${evidence_provider}" != phase4-mtls-* ]]; then
      echo "Secure flow selected unexpected evidence provider: ${evidence_provider}" >&2
      return 1
    fi
  fi

  echo "Selected providers (${flow_name}): policy=${policy_provider}, evidence=${evidence_provider}"

  run_id="${flow_name}-$(date +%Y%m%d%H%M%S)"
  now_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  start_port_forward_for_provider "${policy_provider}" "${POLICY_LOCAL_PORT}"

  if [ "${expected_decision}" = "DENY" ]; then
    cat >"${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.json" <<JSON
{
  "meta": {
    "requestId": "phase4-${flow_name}-policy-eval-${run_id}",
    "timestamp": "${now_ts}",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "prod"
  },
  "subject": {
    "type": "user",
    "id": "deny-user",
    "attributes": {
      "approvedForProd": false
    }
  },
  "action": {
    "verb": "delete",
    "target": "inferenceservice"
  },
  "resource": {
    "kind": "InferenceService",
    "namespace": "${KSERVE_NAMESPACE}",
    "name": "${KSERVE_ISVC_NAME}"
  },
  "context": {
    "kserve": {
      "namespace": "${KSERVE_NAMESPACE}",
      "inferenceService": "${KSERVE_ISVC_NAME}",
      "response": ${kserve_response_json}
    }
  },
  "mode": "enforce"
}
JSON
  else
    cat >"${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.json" <<JSON
{
  "meta": {
    "requestId": "phase4-${flow_name}-policy-eval-${run_id}",
    "timestamp": "${now_ts}",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "dev"
  },
  "subject": {
    "type": "serviceaccount",
    "id": "kserve-smoke"
  },
  "action": {
    "verb": "predict",
    "target": "inferenceservice"
  },
  "resource": {
    "kind": "InferenceService",
    "namespace": "${KSERVE_NAMESPACE}",
    "name": "${KSERVE_ISVC_NAME}"
  },
  "context": {
    "kserve": {
      "namespace": "${KSERVE_NAMESPACE}",
      "inferenceService": "${KSERVE_ISVC_NAME}",
      "response": ${kserve_response_json}
    }
  },
  "mode": "enforce"
}
JSON
  fi

  current_post_json "/v1alpha1/policy-provider/evaluate" \
    "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.json" \
    "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json"

  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json" "\"decision\"[[:space:]]*:[[:space:]]*\"${expected_decision}\"" "${flow_name} policy decision ${expected_decision}"
  if [ "${expected_decision}" = "DENY" ]; then
    assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json" '"reasons"[[:space:]]*:[[:space:]]*\[' "${flow_name} policy deny reasons present"
    assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json" '"(DELETE_DENIED|PROD_APPROVAL_REQUIRED)"' "${flow_name} policy deny reason code"
  fi
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json" '"policyBundle"[[:space:]]*:' "${flow_name} policy bundle metadata"
  stop_port_forward

  start_port_forward_for_provider "${evidence_provider}" "${EVIDENCE_LOCAL_PORT}"

  local evidence_environment="dev"
  local evidence_event_type="kserve.inference.authorized"
  local evidence_event_id="phase4-${flow_name}-policy-allow-${run_id}"
  local evidence_stage="authorize"
  if [ "${expected_decision}" = "DENY" ]; then
    evidence_environment="prod"
    evidence_event_type="kserve.inference.denied"
    evidence_event_id="phase4-${flow_name}-policy-deny-${run_id}"
    evidence_stage="deny"
  fi

  cat >"${TMPDIR_LOCAL}/${flow_name}-evidence-record.json" <<JSON
{
  "meta": {
    "requestId": "phase4-${flow_name}-evidence-record-${run_id}",
    "timestamp": "${now_ts}",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "${evidence_environment}"
  },
  "eventType": "${evidence_event_type}",
  "eventId": "${evidence_event_id}",
  "runId": "${run_id}",
  "stage": "${evidence_stage}",
  "payload": {
    "flow": "${flow_name}",
    "expectedDecision": "${expected_decision}",
    "selectedPolicyProvider": "${policy_provider}",
    "selectedEvidenceProvider": "${evidence_provider}",
    "policyDecision": $(cat "${TMPDIR_LOCAL}/${flow_name}-policy-evaluate.out.json"),
    "inferenceResponse": ${kserve_response_json}
  },
  "retentionClass": "standard"
}
JSON

  current_post_json "/v1alpha1/evidence-provider/record" \
    "${TMPDIR_LOCAL}/${flow_name}-evidence-record.json" \
    "${TMPDIR_LOCAL}/${flow_name}-evidence-record.out.json"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-record.out.json" '"accepted"[[:space:]]*:[[:space:]]*true' "${flow_name} evidence record accepted"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-record.out.json" '"evidenceId"[[:space:]]*:[[:space:]]*"evd_' "${flow_name} evidenceId"

  evidence_id="$(extract_json_string "${TMPDIR_LOCAL}/${flow_name}-evidence-record.out.json" evidenceId)"
  if [ -z "${evidence_id}" ]; then
    echo "Failed to parse evidenceId from evidence record response (${flow_name})." >&2
    cat "${TMPDIR_LOCAL}/${flow_name}-evidence-record.out.json" >&2
    return 1
  fi

  cat >"${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.json" <<JSON
{
  "meta": {
    "requestId": "phase4-${flow_name}-evidence-finalize-${run_id}",
    "timestamp": "${now_ts}"
  },
  "bundleId": "bundle-${run_id}",
  "runId": "${run_id}",
  "evidenceIds": ["${evidence_id}"],
  "retentionClass": "standard",
  "annotations": {
    "flow": "${flow_name}",
    "selectedPolicyProvider": "${policy_provider}",
    "selectedEvidenceProvider": "${evidence_provider}",
    "kserveInferenceService": "${KSERVE_NAMESPACE}/${KSERVE_ISVC_NAME}"
  }
}
JSON

  current_post_json "/v1alpha1/evidence-provider/finalize-bundle" \
    "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.json" \
    "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.out.json"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.out.json" '"bundleId"[[:space:]]*:[[:space:]]*"bundle-' "${flow_name} bundleId"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.out.json" '"manifestUri"[[:space:]]*:[[:space:]]*"' "${flow_name} manifestUri"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.out.json" '"manifestChecksum"[[:space:]]*:[[:space:]]*"sha256:' "${flow_name} manifestChecksum"
  assert_response_contains "${TMPDIR_LOCAL}/${flow_name}-evidence-finalize.out.json" '"itemCount"[[:space:]]*:[[:space:]]*[1-9]' "${flow_name} bundle itemCount > 0"
  stop_port_forward

  echo "Phase 04 ${flow_name} flow passed (expectedDecision=${expected_decision})."
  echo "  selected_policy_provider=${policy_provider}"
  echo "  selected_evidence_provider=${evidence_provider}"
  echo "  run_id=${run_id}"
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd grep
  require_cmd sed
  require_cmd tee
  require_cmd base64

  if [ "${RUN_IMAGE_PREP}" = "1" ]; then
    require_cmd docker
    if [ "${RUNTIME}" = "kind" ]; then
      require_cmd kind
    elif [ "${RUNTIME}" = "k3d" ]; then
      require_cmd k3d
    fi
  fi

  if [ "${RUN_SECURE_AUTH_PATH}" = "1" ]; then
    require_cmd openssl
  fi

  run_phase03_if_requested
  prepare_images
  apply_phase04_components

  local kserve_response_json
  kserve_response_json="$(capture_kserve_response)"

  run_policy_evidence_flow "baseline-allow" 0 0 0 "${kserve_response_json}" "ALLOW"
  run_policy_evidence_flow "baseline-deny" 0 0 0 "${kserve_response_json}" "DENY"

  if [ "${RUN_SECURE_AUTH_PATH}" = "1" ]; then
    apply_secure_auth_fixtures
    run_policy_evidence_flow "secure-auth-allow" "${SECURE_POLICY_MIN_PRIORITY}" "${SECURE_EVIDENCE_MIN_PRIORITY}" 1 "${kserve_response_json}" "ALLOW"
    run_policy_evidence_flow "secure-auth-deny" "${SECURE_POLICY_MIN_PRIORITY}" "${SECURE_EVIDENCE_MIN_PRIORITY}" 1 "${kserve_response_json}" "DENY"
  fi

  echo "Phase 04 flow passed (provider selection + policy decision + evidence bundle handoff, ALLOW+DENY)."
}

main "$@"
