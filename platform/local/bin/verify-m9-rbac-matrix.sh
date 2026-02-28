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

LOCAL_PORT="${LOCAL_PORT:-18088}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"

AUTHN_ISSUER="${AUTHN_ISSUER:-epydios-dev}"
AUTHN_AUDIENCE="${AUTHN_AUDIENCE:-epydios-runtime}"
JWT_SECRET="${JWT_SECRET:-epydios-m9-dev-secret}"
ALLOWED_CLIENT_ID="${ALLOWED_CLIENT_ID:-epydios-runtime-client}"
CREATE_ROLE="${CREATE_ROLE:-runtime.run.create}"
READ_ROLE="${READ_ROLE:-runtime.run.read}"

TENANT_ALPHA="${TENANT_ALPHA:-tenant-alpha}"
PROJECT_ALPHA="${PROJECT_ALPHA:-project-a}"
TENANT_BETA="${TENANT_BETA:-tenant-beta}"
PROJECT_BETA="${PROJECT_BETA:-project-z}"
PROJECT_RISK="${PROJECT_RISK:-project-risk}"

default_role_mappings_json() {
  cat <<'JSON'
{"mappings":[{"role":"runtime.platform_admin","permissions":["*"]},{"role":"runtime.tenant_operator","permissions":["runtime.run.create","runtime.run.read"]},{"role":"runtime.tenant_reader","permissions":["runtime.run.read"]}]}
JSON
}

default_policy_matrix_json() {
  cat <<'JSON'
{"rules":[{"name":"deny-risk-project-create","effect":"deny","roles":["runtime.tenant_operator"],"permissions":["runtime.run.create"],"tenants":["tenant-alpha"],"projects":["project-risk"]},{"name":"allow-tenant-alpha-operator","effect":"allow","roles":["runtime.tenant_operator"],"permissions":["runtime.run.create","runtime.run.read"],"tenants":["tenant-alpha"],"projects":["project-a"]},{"name":"allow-tenant-alpha-reader","effect":"allow","roles":["runtime.tenant_reader"],"permissions":["runtime.run.read"],"tenants":["tenant-alpha"],"projects":["project-a"]},{"name":"allow-platform-admin","effect":"allow","roles":["runtime.platform_admin"],"permissions":["*"],"tenants":["*"],"projects":["*"]}]}
JSON
}

ROLE_MAPPINGS_JSON="${ROLE_MAPPINGS_JSON:-$(default_role_mappings_json)}"
POLICY_MATRIX_JSON="${POLICY_MATRIX_JSON:-$(default_policy_matrix_json)}"

PORT_FORWARD_PID=""
AUTH_PATCHED="0"
TMPDIR_LOCAL="$(mktemp -d)"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== M9.4 diagnostics (${NAMESPACE}) ===" >&2
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

  echo "Running M5 baseline before M9.4 RBAC matrix smoke..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

configure_runtime_auth() {
  local role_mappings_compact policy_matrix_compact
  role_mappings_compact="$(printf '%s' "${ROLE_MAPPINGS_JSON}" | tr -d '\n')"
  policy_matrix_compact="$(printf '%s' "${POLICY_MATRIX_JSON}" | tr -d '\n')"

  echo "Configuring runtime authn/authz for M9.4 RBAC policy matrix checks..."
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
    AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON="${role_mappings_compact}" \
    AUTHZ_POLICY_MATRIX_JSON="${policy_matrix_compact}" \
    AUTHZ_POLICY_MATRIX_REQUIRED=true \
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

  cat >"${out_file}" <<JSON
{
  "meta": {
    "requestId": "${request_id}",
    "timestamp": "2026-02-27T00:00:00Z",
    "tenantId": "${tenant_id}",
    "projectId": "${project_id}",
    "environment": "prod"
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

assert_audit_policy_events() {
  local pod logs_file
  pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=orchestration-runtime -o jsonpath='{.items[0].metadata.name}')"
  logs_file="${TMPDIR_LOCAL}/runtime-audit.log"
  kubectl -n "${NAMESPACE}" logs "${pod}" -c runtime --tail=500 >"${logs_file}"

  assert_contains "${logs_file}" '"event":"runtime.authz.policy.allow"' "audit policy allow"
  assert_contains "${logs_file}" '"event":"runtime.authz.policy.deny"' "audit policy deny"
  assert_contains "${logs_file}" 'denied by policy rule' "audit explicit deny rule message"
  assert_contains "${logs_file}" 'no matching allow policy rule' "audit implicit deny message"
}

run_rbac_matrix_smoke() {
  local token_unknown token_reader_alpha token_operator_alpha token_operator_alpha_risk token_operator_beta token_admin
  local status run_alpha run_admin

  token_unknown="$(make_jwt_token "unknown-user" "${ALLOWED_CLIENT_ID}" "runtime.unknown" "${TENANT_ALPHA}" "${PROJECT_ALPHA}")"
  token_reader_alpha="$(make_jwt_token "reader-alpha" "${ALLOWED_CLIENT_ID}" "runtime.tenant_reader" "${TENANT_ALPHA}" "${PROJECT_ALPHA}")"
  token_operator_alpha="$(make_jwt_token "operator-alpha" "${ALLOWED_CLIENT_ID}" "runtime.tenant_operator" "${TENANT_ALPHA}" "${PROJECT_ALPHA}")"
  token_operator_alpha_risk="$(make_jwt_token "operator-alpha-risk" "${ALLOWED_CLIENT_ID}" "runtime.tenant_operator" "${TENANT_ALPHA}" "${PROJECT_RISK}")"
  token_operator_beta="$(make_jwt_token "operator-beta" "${ALLOWED_CLIENT_ID}" "runtime.tenant_operator" "${TENANT_BETA}" "${PROJECT_BETA}")"
  token_admin="$(make_jwt_token "platform-admin" "${ALLOWED_CLIENT_ID}" "runtime.platform_admin" "" "")"

  write_request "${TMPDIR_LOCAL}/req-alpha.json" "m9-rbac-alpha-allow" "${TENANT_ALPHA}" "${PROJECT_ALPHA}"
  write_request "${TMPDIR_LOCAL}/req-beta.json" "m9-rbac-beta-allow-admin" "${TENANT_BETA}" "${PROJECT_BETA}"
  write_request "${TMPDIR_LOCAL}/req-risk.json" "m9-rbac-alpha-risk-deny" "${TENANT_ALPHA}" "${PROJECT_RISK}"

  start_port_forward

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-alpha.json" "" "${TMPDIR_LOCAL}/unauth.json")"
  assert_status "${status}" "401" "unauthenticated denied"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-alpha.json" "${token_unknown}" "${TMPDIR_LOCAL}/unknown-role.json")"
  assert_status "${status}" "403" "unknown role denied"
  assert_contains "${TMPDIR_LOCAL}/unknown-role.json" 'role mapping denied' "unknown role denial message"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-alpha.json" "${token_reader_alpha}" "${TMPDIR_LOCAL}/reader-create.json")"
  assert_status "${status}" "403" "reader create denied"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-alpha.json" "${token_operator_alpha}" "${TMPDIR_LOCAL}/operator-alpha-create.json")"
  assert_status "${status}" "201" "operator alpha create allowed"
  run_alpha="$(extract_json_string "${TMPDIR_LOCAL}/operator-alpha-create.json" "runId")"
  if [ -z "${run_alpha}" ]; then
    echo "Failed to parse runId for operator alpha allow run" >&2
    cat "${TMPDIR_LOCAL}/operator-alpha-create.json" >&2
    return 1
  fi

  status="$(http_json GET "/v1alpha1/runtime/runs/${run_alpha}" "" "${token_reader_alpha}" "${TMPDIR_LOCAL}/reader-alpha-get.json")"
  assert_status "${status}" "200" "reader alpha read allowed"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-risk.json" "${token_operator_alpha_risk}" "${TMPDIR_LOCAL}/operator-alpha-risk.json")"
  assert_status "${status}" "403" "explicit deny policy rule blocks create"
  assert_contains "${TMPDIR_LOCAL}/operator-alpha-risk.json" 'denied by policy rule' "explicit deny rule message"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-beta.json" "${token_operator_beta}" "${TMPDIR_LOCAL}/operator-beta-no-allow.json")"
  assert_status "${status}" "403" "operator beta no matching allow denied"
  assert_contains "${TMPDIR_LOCAL}/operator-beta-no-allow.json" 'no matching allow policy rule' "no matching allow message"

  status="$(http_json POST "/v1alpha1/runtime/runs" "${TMPDIR_LOCAL}/req-beta.json" "${token_admin}" "${TMPDIR_LOCAL}/admin-create.json")"
  assert_status "${status}" "201" "platform admin create allowed"
  run_admin="$(extract_json_string "${TMPDIR_LOCAL}/admin-create.json" "runId")"
  if [ -z "${run_admin}" ]; then
    echo "Failed to parse runId for platform admin allow run" >&2
    cat "${TMPDIR_LOCAL}/admin-create.json" >&2
    return 1
  fi

  status="$(http_json GET "/v1alpha1/runtime/runs/${run_admin}" "" "${token_operator_alpha}" "${TMPDIR_LOCAL}/operator-alpha-read-admin-run.json")"
  assert_status "${status}" "403" "operator alpha cannot read admin tenant run"

  status="$(http_json GET "/v1alpha1/runtime/runs/${run_alpha}" "" "${token_admin}" "${TMPDIR_LOCAL}/admin-read-alpha-run.json")"
  assert_status "${status}" "200" "platform admin can read alpha run"

  status="$(http_json GET "/v1alpha1/runtime/runs?limit=20" "" "${token_reader_alpha}" "${TMPDIR_LOCAL}/reader-list.json")"
  assert_status "${status}" "200" "reader list allowed"
  assert_contains "${TMPDIR_LOCAL}/reader-list.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_alpha}\"" "reader list contains alpha run"
  assert_not_contains "${TMPDIR_LOCAL}/reader-list.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_admin}\"" "reader list excludes admin beta run"

  status="$(http_json GET "/v1alpha1/runtime/runs?limit=20" "" "${token_admin}" "${TMPDIR_LOCAL}/admin-list.json")"
  assert_status "${status}" "200" "admin list allowed"
  assert_contains "${TMPDIR_LOCAL}/admin-list.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_alpha}\"" "admin list contains alpha run"
  assert_contains "${TMPDIR_LOCAL}/admin-list.json" "\"runId\"[[:space:]]*:[[:space:]]*\"${run_admin}\"" "admin list contains beta run"

  assert_audit_policy_events
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
  run_rbac_matrix_smoke

  echo "M9.4 RBAC/policy matrix smoke passed (OIDC role mapping + tenant/project allow/deny matrix)."
}

main "$@"
