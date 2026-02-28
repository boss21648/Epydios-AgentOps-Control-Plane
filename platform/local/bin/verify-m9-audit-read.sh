#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"

RUN_M5_BASELINE="${RUN_M5_BASELINE:-1}"
RUN_M5_BOOTSTRAP="${RUN_M5_BOOTSTRAP:-0}"
RUN_M5_IMAGE_PREP="${RUN_M5_IMAGE_PREP:-1}"

LOCAL_PORT="${LOCAL_PORT:-18089}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"

AUTHN_ISSUER="${AUTHN_ISSUER:-epydios-dev}"
AUTHN_AUDIENCE="${AUTHN_AUDIENCE:-epydios-runtime}"
JWT_SECRET="${JWT_SECRET:-epydios-m9-dev-secret}"
ALLOWED_CLIENT_ID="${ALLOWED_CLIENT_ID:-epydios-runtime-client}"
CREATE_ROLE="${CREATE_ROLE:-runtime.run.create}"
READ_ROLE="${READ_ROLE:-runtime.run.read}"

TENANT_A="${TENANT_A:-tenant-a}"
PROJECT_A="${PROJECT_A:-project-a}"
TENANT_B="${TENANT_B:-tenant-b}"
PROJECT_B="${PROJECT_B:-project-b}"

PORT_FORWARD_PID=""
AUTH_PATCHED="0"
TMPDIR_LOCAL="$(mktemp -d)"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== M9.5 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deploy,svc,pods,extensionprovider -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" get deploy/orchestration-runtime -o jsonpath='{.spec.template.spec.containers[0].env}' >&2 || true
  echo >&2

  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=orchestration-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    echo "--- logs pod/${pod} container=runtime ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --tail=400 >&2 || true
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

restore_runtime_auth() {
  if [ "${AUTH_PATCHED}" != "1" ]; then
    return 0
  fi

  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime \
    AUTHN_ENABLED=false \
    AUTHN_HS256_SECRET- \
    AUTHN_ISSUER- \
    AUTHN_AUDIENCE- \
    AUTHN_JWKS_URL- \
    AUTHN_JWKS_CACHE_TTL- \
    AUTHN_ROLE_CLAIM- \
    AUTHN_CLIENT_ID_CLAIM- \
    AUTHN_TENANT_CLAIM- \
    AUTHN_PROJECT_CLAIM- \
    AUTHZ_CREATE_ROLES- \
    AUTHZ_READ_ROLES- \
    AUTHZ_ALLOWED_CLIENT_IDS- \
    AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON- \
    AUTHZ_POLICY_MATRIX_JSON- \
    AUTHZ_POLICY_MATRIX_REQUIRED- \
    >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deployment/orchestration-runtime --timeout=6m >/dev/null 2>&1 || true
  AUTH_PATCHED="0"
}

cleanup() {
  stop_port_forward
  restore_runtime_auth
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

run_m5_if_requested() {
  if [ "${RUN_M5_BASELINE}" != "1" ]; then
    return 0
  fi

  echo "Running M5 baseline before M9.5 audit-read smoke..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

configure_runtime_auth() {
  echo "Configuring runtime authn/authz for M9.5 audit-read checks..."
  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime \
    AUTHN_ENABLED=true \
    AUTHN_ISSUER="${AUTHN_ISSUER}" \
    AUTHN_AUDIENCE="${AUTHN_AUDIENCE}" \
    AUTHN_JWKS_URL= \
    AUTHN_HS256_SECRET="${JWT_SECRET}" \
    AUTHN_JWKS_CACHE_TTL=5m \
    AUTHN_ROLE_CLAIM=roles \
    AUTHN_CLIENT_ID_CLAIM=client_id \
    AUTHN_TENANT_CLAIM=tenant_id \
    AUTHN_PROJECT_CLAIM=project_id \
    AUTHZ_CREATE_ROLES="${CREATE_ROLE}" \
    AUTHZ_READ_ROLES="${READ_ROLE}" \
    AUTHZ_ALLOWED_CLIENT_IDS="${ALLOWED_CLIENT_ID}" \
    AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON= \
    AUTHZ_POLICY_MATRIX_JSON= \
    AUTHZ_POLICY_MATRIX_REQUIRED=false \
    >/dev/null
  AUTH_PATCHED="1"
  kubectl -n "${NAMESPACE}" rollout status deployment/orchestration-runtime --timeout=8m
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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

roles_json_array() {
  local csv="$1"
  local out=""
  local first=1
  IFS=',' read -r -a items <<< "${csv}"
  for raw in "${items[@]}"; do
    local role
    role="$(trim "${raw}")"
    if [ -z "${role}" ]; then
      continue
    fi
    if [ "${first}" -eq 0 ]; then
      out="${out},"
    fi
    out="${out}\"${role}\""
    first=0
  done
  printf '%s' "${out}"
}

make_jwt_token() {
  local subject="$1"
  local client_id="$2"
  local roles_csv="$3"
  local tenant_id="$4"
  local project_id="$5"
  local now exp payload header signing_input signature

  now="$(date +%s)"
  exp=$(( now + 600 ))
  header='{"alg":"HS256","typ":"JWT"}'
  payload="$(printf '{"iss":"%s","aud":"%s","sub":"%s","client_id":"%s","roles":[%s],"tenant_id":"%s","project_id":"%s","iat":%d,"exp":%d}' \
    "${AUTHN_ISSUER}" "${AUTHN_AUDIENCE}" "${subject}" "${client_id}" "$(roles_json_array "${roles_csv}")" "${tenant_id}" "${project_id}" "${now}" "${exp}")"

  local header_b64 payload_b64
  header_b64="$(printf '%s' "${header}" | b64url)"
  payload_b64="$(printf '%s' "${payload}" | b64url)"
  signing_input="${header_b64}.${payload_b64}"
  signature="$(printf '%s' "${signing_input}" | openssl dgst -binary -sha256 -hmac "${JWT_SECRET}" | b64url)"
  printf '%s.%s.%s' "${header_b64}" "${payload_b64}" "${signature}"
}

write_request() {
  local out_file="$1"
  local request_id="$2"
  local tenant_id="$3"
  local project_id="$4"
  local verb="$5"

  cat >"${out_file}" <<JSON
{
  "meta": {
    "requestId": "${request_id}",
    "timestamp": "2026-02-27T00:00:00Z",
    "tenantId": "${tenant_id}",
    "projectId": "${project_id}",
    "environment": "dev"
  },
  "subject": {
    "type": "user",
    "id": "alice"
  },
  "action": {
    "verb": "${verb}",
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
}

http_json() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local token="${4:-}"
  local out_file="$5"

  local -a cmd
  cmd=(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w "%{http_code}" -X "${method}" "http://127.0.0.1:${LOCAL_PORT}${path}")
  if [ -n "${token}" ]; then
    cmd+=(-H "Authorization: Bearer ${token}")
  fi
  if [ -n "${body_file}" ]; then
    cmd+=(-H "Content-Type: application/json" --data-binary @"${body_file}")
  fi
  "${cmd[@]}"
}

assert_status() {
  local got="$1"
  local expected="$2"
  local label="$3"
  if [ "${got}" != "${expected}" ]; then
    echo "Assertion failed for ${label}: status=${got} expected=${expected}" >&2
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "${pattern}" "${file}"; then
    echo "Assertion failed for ${label}: pattern ${pattern} not found" >&2
    cat "${file}" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq "${pattern}" "${file}"; then
    echo "Assertion failed for ${label}: unexpected pattern ${pattern} found" >&2
    cat "${file}" >&2
    return 1
  fi
}

extract_json_string() {
  local file="$1"
  local field="$2"
  grep -Eo "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "${file}" | head -n 1 | sed -E "s/.*:[[:space:]]*\"([^\"]+)\"/\\1/"
}

run_audit_endpoint_smoke() {
  local token_operator_a token_reader_a token_reader_global token_operator_b
  local status run_allow_a run_deny_a run_allow_b policy_provider

  token_operator_a="$(make_jwt_token "tenant-a-operator" "${ALLOWED_CLIENT_ID}" "${CREATE_ROLE},${READ_ROLE}" "${TENANT_A}" "${PROJECT_A}")"
  token_reader_a="$(make_jwt_token "tenant-a-reader" "${ALLOWED_CLIENT_ID}" "${READ_ROLE}" "${TENANT_A}" "${PROJECT_A}")"
  token_reader_global="$(make_jwt_token "global-audit-reader" "${ALLOWED_CLIENT_ID}" "${READ_ROLE}" "" "")"
  token_operator_b="$(make_jwt_token "tenant-b-operator" "${ALLOWED_CLIENT_ID}" "${CREATE_ROLE},${READ_ROLE}" "${TENANT_B}" "${PROJECT_B}")"

  write_request "${TMPDIR_LOCAL}/allow-a.json" "m9-audit-allow-a" "${TENANT_A}" "${PROJECT_A}" "read"
  write_request "${TMPDIR_LOCAL}/deny-a.json" "m9-audit-deny-a" "${TENANT_A}" "${PROJECT_A}" "delete"
  write_request "${TMPDIR_LOCAL}/allow-b.json" "m9-audit-allow-b" "${TENANT_B}" "${PROJECT_B}" "read"

  start_port_forward

  status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=10" "" "" "${TMPDIR_LOCAL}/audit-unauth.json")"
  assert_status "${status}" "401" "unauthenticated audit list denied"
  assert_contains "${TMPDIR_LOCAL}/audit-unauth.json" '"errorCode"[[:space:]]*:[[:space:]]*"UNAUTHORIZED"' "unauthenticated audit error code"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/allow-a.json" "${token_operator_a}" "${TMPDIR_LOCAL}/allow-a.out.json")"
  assert_status "${status}" "201" "tenant-a allow run created"
  assert_contains "${TMPDIR_LOCAL}/allow-a.out.json" '"policyDecision"[[:space:]]*:[[:space:]]*"ALLOW"' "tenant-a allow decision"
  run_allow_a="$(extract_json_string "${TMPDIR_LOCAL}/allow-a.out.json" "runId")"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/deny-a.json" "${token_operator_a}" "${TMPDIR_LOCAL}/deny-a.out.json")"
  assert_status "${status}" "201" "tenant-a deny run created"
  assert_contains "${TMPDIR_LOCAL}/deny-a.out.json" '"policyDecision"[[:space:]]*:[[:space:]]*"DENY"' "tenant-a deny decision"
  run_deny_a="$(extract_json_string "${TMPDIR_LOCAL}/deny-a.out.json" "runId")"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/allow-b.json" "${token_operator_b}" "${TMPDIR_LOCAL}/allow-b.out.json")"
  assert_status "${status}" "201" "tenant-b run created"
  run_allow_b="$(extract_json_string "${TMPDIR_LOCAL}/allow-b.out.json" "runId")"

  if [ -z "${run_allow_a}" ] || [ -z "${run_deny_a}" ] || [ -z "${run_allow_b}" ]; then
    echo "Failed to parse one or more run IDs from runtime responses" >&2
    return 1
  fi

  policy_provider="$(extract_json_string "${TMPDIR_LOCAL}/allow-a.out.json" "selectedPolicyProvider")"
  sleep 2

  status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=200" "" "${token_reader_a}" "${TMPDIR_LOCAL}/audit-reader-a.out.json")"
  assert_status "${status}" "200" "tenant-a reader audit list allowed"
  assert_contains "${TMPDIR_LOCAL}/audit-reader-a.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_allow_a}\"" "audit list contains tenant-a allow run"
  assert_contains "${TMPDIR_LOCAL}/audit-reader-a.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_deny_a}\"" "audit list contains tenant-a deny run"
  assert_not_contains "${TMPDIR_LOCAL}/audit-reader-a.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_allow_b}\"" "audit list excludes tenant-b run"

  status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=200&tenantId=${TENANT_A}&projectId=${PROJECT_A}&decision=DENY" "" "${token_reader_a}" "${TMPDIR_LOCAL}/audit-deny-filter.out.json")"
  assert_status "${status}" "200" "audit deny filter allowed"
  assert_contains "${TMPDIR_LOCAL}/audit-deny-filter.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_deny_a}\"" "deny filter contains deny run"
  assert_not_contains "${TMPDIR_LOCAL}/audit-deny-filter.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_allow_a}\"" "deny filter excludes allow run"

  if [ -n "${policy_provider}" ]; then
    status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=200&event=runtime.policy.decision&providerId=${policy_provider}" "" "${token_reader_global}" "${TMPDIR_LOCAL}/audit-provider-filter.out.json")"
    assert_status "${status}" "200" "audit provider filter allowed"
    assert_contains "${TMPDIR_LOCAL}/audit-provider-filter.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_allow_a}\"" "provider filter contains seeded run"
    assert_contains "${TMPDIR_LOCAL}/audit-provider-filter.out.json" "\"(providerId|policyProvider)\"[[:space:]]*:[[:space:]]*\"${policy_provider}\"" "provider filter contains policy provider"
  fi

  status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=200&tenantId=${TENANT_B}" "" "${token_reader_a}" "${TMPDIR_LOCAL}/audit-cross-tenant-filter.out.json")"
  assert_status "${status}" "200" "cross-tenant filter request allowed"
  assert_contains "${TMPDIR_LOCAL}/audit-cross-tenant-filter.out.json" '"count"[[:space:]]*:[[:space:]]*0' "cross-tenant filter returns zero rows"

  status="$(http_json GET "/v1alpha1/runtime/audit/events?limit=abc" "" "${token_reader_a}" "${TMPDIR_LOCAL}/audit-invalid-limit.out.json")"
  assert_status "${status}" "400" "invalid audit limit rejected"
  assert_contains "${TMPDIR_LOCAL}/audit-invalid-limit.out.json" '"errorCode"[[:space:]]*:[[:space:]]*"INVALID_LIMIT"' "invalid limit error code"
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd openssl
  if [ "${RUN_M5_BASELINE}" = "1" ] || [ "${RUN_M5_IMAGE_PREP}" = "1" ]; then
    require_cmd docker
  fi

  case "${RUNTIME}" in
    kind) require_cmd kind ;;
    k3d) require_cmd k3d ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac

  run_m5_if_requested
  wait_for_deployment orchestration-runtime
  configure_runtime_auth
  run_audit_endpoint_smoke

  echo "M9.5 runtime audit read endpoint smoke passed (authz + scoped filtering + provider/decision filters)."
}

main "$@"
