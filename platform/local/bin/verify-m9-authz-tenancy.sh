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

LOCAL_PORT="${LOCAL_PORT:-18087}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-15}"

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
  echo "=== M9.2/M9.3 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deploy,svc,pods,extensionprovider -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" get deploy/orchestration-runtime -o jsonpath='{.spec.template.spec.containers[0].env}' >&2 || true
  echo >&2

  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=orchestration-runtime -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    echo "--- logs pod/${pod} container=runtime ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --tail=300 >&2 || true
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

  echo "Running M5 baseline before M9.2/M9.3 authz-tenancy smoke..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

configure_runtime_auth() {
  echo "Configuring runtime authn/authz for tenant/project scope checks..."
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

  local enabled
  enabled="$(kubectl -n "${NAMESPACE}" get deploy/orchestration-runtime -o jsonpath='{range .spec.template.spec.containers[?(@.name=="runtime")].env[?(@.name=="AUTHN_ENABLED")]}{.value}{end}')"
  if [ "${enabled}" != "true" ]; then
    echo "Failed to set AUTHN_ENABLED=true on orchestration-runtime deployment (got: ${enabled})" >&2
    return 1
  fi
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
}

write_request_no_scope() {
  local out_file="$1"
  local request_id="$2"
  cat >"${out_file}" <<JSON
{
  "meta": {
    "requestId": "${request_id}",
    "timestamp": "2026-02-27T00:00:00Z",
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

assert_audit_events_present() {
  local pod logs_file
  pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=orchestration-runtime -o jsonpath='{.items[0].metadata.name}')"
  logs_file="${TMPDIR_LOCAL}/runtime-audit.log"
  kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --tail=400 >"${logs_file}"

  assert_contains "${logs_file}" '"event":"runtime.authz.allow"' "audit authz allow"
  assert_contains "${logs_file}" '"event":"runtime.scope.deny"' "audit scope deny"
  assert_contains "${logs_file}" '"event":"runtime.provider.selected"' "audit provider selected"
  assert_contains "${logs_file}" '"event":"runtime.policy.decision"' "audit policy decision"
  assert_contains "${logs_file}" '"event":"runtime.run.completed"' "audit run completed"
}

run_authz_tenancy_smoke() {
  local token_a token_b token_a_reader status run_a run_auto
  token_a="$(make_jwt_token "tenant-a-user" "${ALLOWED_CLIENT_ID}" "${CREATE_ROLE},${READ_ROLE}" "${TENANT_A}" "${PROJECT_A}")"
  token_a_reader="$(make_jwt_token "tenant-a-reader" "${ALLOWED_CLIENT_ID}" "${READ_ROLE}" "${TENANT_A}" "${PROJECT_A}")"
  token_b="$(make_jwt_token "tenant-b-user" "${ALLOWED_CLIENT_ID}" "${CREATE_ROLE},${READ_ROLE}" "${TENANT_B}" "${PROJECT_B}")"

  write_request "${TMPDIR_LOCAL}/create-a.json" "m9-tenancy-allow-a" "${TENANT_A}" "${PROJECT_A}"
  write_request "${TMPDIR_LOCAL}/create-cross-tenant.json" "m9-tenancy-deny-tenant" "${TENANT_B}" "${PROJECT_A}"
  write_request "${TMPDIR_LOCAL}/create-cross-project.json" "m9-tenancy-deny-project" "${TENANT_A}" "${PROJECT_B}"
  write_request_no_scope "${TMPDIR_LOCAL}/create-autoscope.json" "m9-tenancy-autoscope-a"

  start_port_forward

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/create-a.json" "" "${TMPDIR_LOCAL}/unauth-create.out.json")"
  assert_status "${status}" "401" "unauthenticated create denied"
  assert_contains "${TMPDIR_LOCAL}/unauth-create.out.json" '"errorCode"[[:space:]]*:[[:space:]]*"UNAUTHORIZED"' "unauthenticated create error"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/create-a.json" "${token_a}" "${TMPDIR_LOCAL}/create-a.out.json")"
  assert_status "${status}" "201" "tenant-a create allowed"
  run_a="$(extract_json_string "${TMPDIR_LOCAL}/create-a.out.json" "runId")"
  if [ -z "${run_a}" ]; then
    echo "Failed to parse runId from tenant-a create response" >&2
    cat "${TMPDIR_LOCAL}/create-a.out.json" >&2
    return 1
  fi

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/create-cross-tenant.json" "${token_a}" "${TMPDIR_LOCAL}/cross-tenant.out.json")"
  assert_status "${status}" "403" "cross-tenant create denied"
  assert_contains "${TMPDIR_LOCAL}/cross-tenant.out.json" '"errorCode"[[:space:]]*:[[:space:]]*"FORBIDDEN"' "cross-tenant forbidden"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/create-cross-project.json" "${token_a}" "${TMPDIR_LOCAL}/cross-project.out.json")"
  assert_status "${status}" "403" "cross-project create denied"
  assert_contains "${TMPDIR_LOCAL}/cross-project.out.json" '"errorCode"[[:space:]]*:[[:space:]]*"FORBIDDEN"' "cross-project forbidden"

  status="$(http_json GET "/v1alpha1/runtime/runs/${run_a}" "" "${token_b}" "${TMPDIR_LOCAL}/cross-tenant-read.out.json")"
  assert_status "${status}" "403" "cross-tenant read denied"
  assert_contains "${TMPDIR_LOCAL}/cross-tenant-read.out.json" '"errorCode"[[:space:]]*:[[:space:]]*"FORBIDDEN"' "cross-tenant read forbidden"

  status="$(http_json GET "/v1alpha1/runtime/runs/${run_a}" "" "${token_a_reader}" "${TMPDIR_LOCAL}/tenant-a-read.out.json")"
  assert_status "${status}" "200" "in-tenant read allowed"
  assert_contains "${TMPDIR_LOCAL}/tenant-a-read.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_a}\"" "in-tenant read runId"

  status="$(http_json GET "/v1alpha1/runtime/runs?limit=10" "" "${token_b}" "${TMPDIR_LOCAL}/tenant-b-list.out.json")"
  assert_status "${status}" "200" "tenant-b list allowed"
  assert_not_contains "${TMPDIR_LOCAL}/tenant-b-list.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_a}\"" "tenant-b list does not contain tenant-a run"

  status="$(http_json GET "/v1alpha1/runtime/runs?limit=10" "" "${token_a_reader}" "${TMPDIR_LOCAL}/tenant-a-list.out.json")"
  assert_status "${status}" "200" "tenant-a list allowed"
  assert_contains "${TMPDIR_LOCAL}/tenant-a-list.out.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_a}\"" "tenant-a list contains tenant-a run"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/create-autoscope.json" "${token_a}" "${TMPDIR_LOCAL}/create-autoscope.out.json")"
  assert_status "${status}" "201" "auto-scope create allowed"
  assert_contains "${TMPDIR_LOCAL}/create-autoscope.out.json" "\"tenantId\"[[:space:]]*:[[:space:]]*\"${TENANT_A}\"" "auto-scope tenant injected"
  assert_contains "${TMPDIR_LOCAL}/create-autoscope.out.json" "\"projectId\"[[:space:]]*:[[:space:]]*\"${PROJECT_A}\"" "auto-scope project injected"
  run_auto="$(extract_json_string "${TMPDIR_LOCAL}/create-autoscope.out.json" "runId")"
  if [ -z "${run_auto}" ]; then
    echo "Failed to parse runId from auto-scope response" >&2
    cat "${TMPDIR_LOCAL}/create-autoscope.out.json" >&2
    return 1
  fi

  assert_audit_events_present
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
  run_authz_tenancy_smoke

  echo "M9.2/M9.3 runtime authz-tenancy + audit smoke passed (cross-tenant blocked, in-tenant allowed, audit events emitted)."
}

main "$@"
