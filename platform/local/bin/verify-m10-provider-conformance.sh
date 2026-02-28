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
RUN_IMAGE_PREP="${RUN_IMAGE_PREP:-1}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-360}"

TOKEN_VALUE="${TOKEN_VALUE:-epydios-m10-bearer-token}"

LOCAL_PORT_PROFILE_NONE="${LOCAL_PORT_PROFILE_NONE:-18110}"
LOCAL_PORT_POLICY_NONE="${LOCAL_PORT_POLICY_NONE:-18111}"
LOCAL_PORT_EVIDENCE_NONE="${LOCAL_PORT_EVIDENCE_NONE:-18112}"
LOCAL_PORT_MTLS_PROFILE="${LOCAL_PORT_MTLS_PROFILE:-18120}"
LOCAL_PORT_MTLS_POLICY="${LOCAL_PORT_MTLS_POLICY:-18121}"
LOCAL_PORT_MTLS_EVIDENCE="${LOCAL_PORT_MTLS_EVIDENCE:-18122}"

CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"

REQUEST_FIXTURES_DIR="${REPO_ROOT}/platform/tests/provider-conformance/requests"
BEARER_FIXTURES_DIR="${REPO_ROOT}/platform/tests/provider-conformance-bearer"
MTLS_FIXTURES_DIR="${REPO_ROOT}/platform/tests/provider-conformance-mtls"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
TMPDIR_LOCAL="$(mktemp -d)"
declare -a CURL_TIMEOUT_ARGS
declare -a MTLS_CURL_OPTS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")
MTLS_CURL_OPTS=()

dump_diagnostics() {
  echo
  echo "=== M10 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get extensionprovider,deploy,svc,pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/extension-provider-registry-controller >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/oss-profile-static-resolver >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/epydios-oss-policy-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/epydios-oss-evidence-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/m10-mtls-profile-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/m10-mtls-policy-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/m10-mtls-bearer-evidence-provider >&2 || true

  local controller_pod
  controller_pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=extension-provider-registry-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${controller_pod}" ]; then
    echo "--- logs pod/${controller_pod} container=controller ---" >&2
    kubectl -n "${NAMESPACE}" logs "${controller_pod}" -c controller --tail=300 >&2 || true
    echo "--- previous logs pod/${controller_pod} container=controller (if any) ---" >&2
    kubectl -n "${NAMESPACE}" logs "${controller_pod}" -c controller --previous --tail=200 >&2 || true
  fi
}

stop_port_forward() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  PORT_FORWARD_PID=""
  PORT_FORWARD_LOG=""
}

cleanup() {
  stop_port_forward
  if [ "${KEEP_RESOURCES}" != "1" ]; then
    kubectl delete -k "${BEARER_FIXTURES_DIR}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -k "${MTLS_FIXTURES_DIR}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "${NAMESPACE}" delete secret \
      m10-bearer-auth \
      m10-mtls-controller-client \
      m10-mtls-provider-ca \
      m10-mtls-server-tls \
      m10-mtls-bearer-client-token \
      m10-mtls-bearer-provider-token \
      --ignore-not-found >/dev/null 2>&1 || true
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

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout=8m
}

wait_for_provider_ready() {
  local name="$1"
  local expected_provider_id="${2:-}"
  local start
  start="$(date +%s)"

  while true; do
    local statuses provider_id
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    provider_id="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" \
        -o jsonpath='{.status.resolved.providerId}' 2>/dev/null || true
    )"

    if printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'; then
      if [ -z "${expected_provider_id}" ] || [ "${provider_id}" = "${expected_provider_id}" ]; then
        echo "Provider ready: ${name} (resolved.providerId=${provider_id})"
        return 0
      fi
    fi

    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider ready/probed on ${name}" >&2
      echo "statuses=${statuses}" >&2
      echo "resolved.providerId=${provider_id}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

wait_for_provider_failure() {
  local name="$1"
  local expected_pattern="$2"
  local start
  start="$(date +%s)"

  while true; do
    local statuses last_probe_error condition_messages ready_msg probed_msg error_text
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    last_probe_error="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" \
        -o jsonpath='{.status.lastProbeError}' 2>/dev/null || true
    )"
    condition_messages="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.message}{"\n"}{end}' 2>/dev/null || true
    )"
    ready_msg="$(printf '%s\n' "${condition_messages}" | awk -F= '$1=="Ready"{sub(/^[^=]*=/,""); print $0; exit}')"
    probed_msg="$(printf '%s\n' "${condition_messages}" | awk -F= '$1=="Probed"{sub(/^[^=]*=/,""); print $0; exit}')"
    error_text="${last_probe_error}"
    if [ -z "${error_text}" ]; then
      error_text="${ready_msg}; ${probed_msg}"
    fi

    if printf '%s' "${statuses}" | grep -q 'Ready=False' && printf '%s' "${statuses}" | grep -q 'Probed=False'; then
      if printf '%s' "${error_text}" | grep -Eiq "${expected_pattern}"; then
        echo "Provider negative case passed: ${name} -> ${error_text}"
        return 0
      fi
    fi

    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider failure on ${name}" >&2
      echo "statuses=${statuses}" >&2
      echo "error_text=${error_text}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

run_m5_if_requested() {
  if [ "${RUN_M5_BASELINE}" != "1" ]; then
    return 0
  fi
  echo "Running M5 baseline before M10 provider conformance..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

prepare_images_if_requested() {
  if [ "${RUN_IMAGE_PREP}" != "1" ]; then
    return 0
  fi

  echo "Building/loading local provider images for M10 conformance..."
  INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER=1 \
    "${SCRIPT_DIR}/build-local-images.sh"

  case "${RUNTIME}" in
    kind)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER=1 \
        "${SCRIPT_DIR}/load-local-images-kind.sh"
      ;;
    k3d)
      CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 INCLUDE_MTLS_PROVIDER=1 \
        "${SCRIPT_DIR}/load-local-images-k3d.sh"
      ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac
}

apply_base_manifests() {
  kubectl apply -k "${REPO_ROOT}/platform/system"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-policy-opa"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-evidence-memory"

  wait_for_deployment extension-provider-registry-controller
  wait_for_deployment oss-profile-static-resolver
  wait_for_deployment epydios-oss-policy-provider
  wait_for_deployment epydios-oss-evidence-provider

  wait_for_provider_ready oss-profile-static oss-profile-static
  wait_for_provider_ready oss-policy-opa oss-policy-opa
  wait_for_provider_ready oss-evidence-memory oss-evidence-memory
}

generate_mtls_pki() {
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=epydios-m10-mtls-ca" \
    -keyout "${TMPDIR_LOCAL}/ca.key" \
    -out "${TMPDIR_LOCAL}/ca.crt" >/dev/null 2>&1

  cat >"${TMPDIR_LOCAL}/server.ext" <<'EOF'
subjectAltName=DNS:m10-mtls-profile-provider.epydios-system.svc.cluster.local,DNS:m10-mtls-policy-provider.epydios-system.svc.cluster.local,DNS:m10-mtls-bearer-evidence-provider.epydios-system.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=epydios-m10-mtls-provider" \
    -keyout "${TMPDIR_LOCAL}/server.key" \
    -out "${TMPDIR_LOCAL}/server.csr" >/dev/null 2>&1
  openssl x509 -req \
    -in "${TMPDIR_LOCAL}/server.csr" \
    -CA "${TMPDIR_LOCAL}/ca.crt" \
    -CAkey "${TMPDIR_LOCAL}/ca.key" \
    -CAcreateserial \
    -out "${TMPDIR_LOCAL}/server.crt" \
    -days 825 \
    -sha256 \
    -extfile "${TMPDIR_LOCAL}/server.ext" >/dev/null 2>&1

  cat >"${TMPDIR_LOCAL}/client.ext" <<'EOF'
extendedKeyUsage=clientAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=extension-provider-registry-controller" \
    -keyout "${TMPDIR_LOCAL}/client.key" \
    -out "${TMPDIR_LOCAL}/client.csr" >/dev/null 2>&1
  openssl x509 -req \
    -in "${TMPDIR_LOCAL}/client.csr" \
    -CA "${TMPDIR_LOCAL}/ca.crt" \
    -CAkey "${TMPDIR_LOCAL}/ca.key" \
    -CAcreateserial \
    -out "${TMPDIR_LOCAL}/client.crt" \
    -days 825 \
    -sha256 \
    -extfile "${TMPDIR_LOCAL}/client.ext" >/dev/null 2>&1

  MTLS_CURL_OPTS=(
    --cacert "${TMPDIR_LOCAL}/ca.crt"
    --cert "${TMPDIR_LOCAL}/client.crt"
    --key "${TMPDIR_LOCAL}/client.key"
  )
}

apply_mtls_secrets() {
  kubectl -n "${NAMESPACE}" create secret tls m10-mtls-controller-client \
    --cert="${TMPDIR_LOCAL}/client.crt" \
    --key="${TMPDIR_LOCAL}/client.key" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic m10-mtls-provider-ca \
    --from-file=ca.crt="${TMPDIR_LOCAL}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic m10-mtls-server-tls \
    --from-file=tls.crt="${TMPDIR_LOCAL}/server.crt" \
    --from-file=tls.key="${TMPDIR_LOCAL}/server.key" \
    --from-file=ca.crt="${TMPDIR_LOCAL}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic m10-mtls-bearer-client-token \
    --from-literal=token="${TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic m10-mtls-bearer-provider-token \
    --from-literal=token="${TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_bearer_fixtures() {
  kubectl -n "${NAMESPACE}" create secret generic m10-bearer-auth \
    --from-literal=token="${TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -k "${BEARER_FIXTURES_DIR}"

  wait_for_provider_ready m10-bearer-profile oss-profile-static
  wait_for_provider_ready m10-bearer-policy oss-policy-opa
  wait_for_provider_ready m10-bearer-evidence oss-evidence-memory
  wait_for_provider_failure m10-bearer-missing-secret "read bearer token secret|not found"
}

apply_mtls_fixtures() {
  generate_mtls_pki
  apply_mtls_secrets
  kubectl apply -k "${MTLS_FIXTURES_DIR}"

  wait_for_deployment m10-mtls-profile-provider
  wait_for_deployment m10-mtls-policy-provider
  wait_for_deployment m10-mtls-bearer-evidence-provider

  wait_for_provider_ready m10-mtls-profile m10-mtls-profile-provider
  wait_for_provider_ready m10-mtls-policy m10-mtls-policy-provider
  wait_for_provider_ready m10-mtls-bearer-evidence m10-mtls-bearer-evidence-provider
}

start_port_forward() {
  local service="$1"
  local local_port="$2"
  local target_port="$3"

  stop_port_forward
  PORT_FORWARD_LOG="${TMPDIR_LOCAL}/port-forward-${service}.log"
  kubectl -n "${NAMESPACE}" port-forward "svc/${service}" "${local_port}:${target_port}" >"${PORT_FORWARD_LOG}" 2>&1 &
  PORT_FORWARD_PID=$!

  local start
  start="$(date +%s)"
  while true; do
    if ! kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
      echo "Port-forward process exited early for ${service}" >&2
      cat "${PORT_FORWARD_LOG}" >&2 || true
      return 1
    fi
    if grep -q "Forwarding from" "${PORT_FORWARD_LOG}" 2>/dev/null; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for port-forward on service ${service}" >&2
      cat "${PORT_FORWARD_LOG}" >&2 || true
      return 1
    fi
    sleep 1
  done
}

request_with_opts() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local token="$4"
  local out_file="$5"
  shift 5
  local -a extra_opts=("$@")
  local curl_err_file status
  curl_err_file="${out_file}.curl.err"
  local -a cmd
  cmd=(curl -sS "${CURL_TIMEOUT_ARGS[@]}" -o "${out_file}" -w "%{http_code}" -X "${method}")
  if [ -n "${token}" ]; then
    cmd+=(-H "Authorization: Bearer ${token}")
  fi
  if [ -n "${body_file}" ]; then
    cmd+=(-H "Content-Type: application/json" --data-binary @"${body_file}")
  fi
  if [ "${#extra_opts[@]}" -gt 0 ]; then
    cmd+=("${extra_opts[@]}")
  fi
  cmd+=("${url}")
  status="$("${cmd[@]}" 2>"${curl_err_file}" || true)"
  if [ -z "${status}" ]; then
    status="000"
  fi
  if [ ! -s "${out_file}" ] && [ -s "${curl_err_file}" ]; then
    cp "${curl_err_file}" "${out_file}" || true
  fi
  rm -f "${curl_err_file}" >/dev/null 2>&1 || true
  printf '%s' "${status}"
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

assert_not_status() {
  local got="$1"
  local not_expected="$2"
  local label="$3"
  if [ "${got}" = "${not_expected}" ]; then
    echo "Assertion failed for ${label}: unexpected status=${got}" >&2
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eiq "${pattern}" "${file}"; then
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

run_none_mode_conformance() {
  local status evidence_id
  echo "Running auth.mode=None provider conformance checks..."

  start_port_forward oss-profile-static-resolver "${LOCAL_PORT_PROFILE_NONE}" 8080
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_PROFILE_NONE}/healthz" "" "" "${TMPDIR_LOCAL}/none-profile-health.json")"
  assert_status "${status}" "200" "none profile health"
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_PROFILE_NONE}/v1alpha1/capabilities" "" "" "${TMPDIR_LOCAL}/none-profile-capabilities.json")"
  assert_status "${status}" "200" "none profile capabilities"
  assert_contains "${TMPDIR_LOCAL}/none-profile-capabilities.json" '"providerType"[[:space:]]*:[[:space:]]*"ProfileResolver"' "none profile provider type"
  assert_contains "${TMPDIR_LOCAL}/none-profile-capabilities.json" '"contractVersion"[[:space:]]*:[[:space:]]*"v1alpha1"' "none profile contract version"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_PROFILE_NONE}/v1alpha1/profile-resolver/resolve" "${REQUEST_FIXTURES_DIR}/profile-resolve.json" "" "${TMPDIR_LOCAL}/none-profile-resolve.json")"
  assert_status "${status}" "200" "none profile resolve"
  assert_contains "${TMPDIR_LOCAL}/none-profile-resolve.json" '"profileId"[[:space:]]*:[[:space:]]*"' "none profile response shape"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_PROFILE_NONE}/v1alpha1/profile-resolver/resolve" "${REQUEST_FIXTURES_DIR}/invalid-json.txt" "" "${TMPDIR_LOCAL}/none-profile-invalid.json")"
  assert_status "${status}" "400" "none profile invalid JSON"

  start_port_forward epydios-oss-policy-provider "${LOCAL_PORT_POLICY_NONE}" 8080
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/healthz" "" "" "${TMPDIR_LOCAL}/none-policy-health.json")"
  assert_status "${status}" "200" "none policy health"
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/capabilities" "" "" "${TMPDIR_LOCAL}/none-policy-capabilities.json")"
  assert_status "${status}" "200" "none policy capabilities"
  assert_contains "${TMPDIR_LOCAL}/none-policy-capabilities.json" '"providerType"[[:space:]]*:[[:space:]]*"PolicyProvider"' "none policy provider type"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/policy-provider/evaluate" "${REQUEST_FIXTURES_DIR}/policy-evaluate-allow.json" "" "${TMPDIR_LOCAL}/none-policy-allow.json")"
  assert_status "${status}" "200" "none policy evaluate allow"
  assert_contains "${TMPDIR_LOCAL}/none-policy-allow.json" '"decision"[[:space:]]*:[[:space:]]*"ALLOW"' "none policy allow decision"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/policy-provider/evaluate" "${REQUEST_FIXTURES_DIR}/policy-evaluate-deny.json" "" "${TMPDIR_LOCAL}/none-policy-deny.json")"
  assert_status "${status}" "200" "none policy evaluate deny"
  assert_contains "${TMPDIR_LOCAL}/none-policy-deny.json" '"decision"[[:space:]]*:[[:space:]]*"DENY"' "none policy deny decision"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/policy-provider/validate-bundle" "${REQUEST_FIXTURES_DIR}/policy-validate-bundle.json" "" "${TMPDIR_LOCAL}/none-policy-validate.json")"
  assert_status "${status}" "200" "none policy validate bundle"
  assert_contains "${TMPDIR_LOCAL}/none-policy-validate.json" '"valid"[[:space:]]*:[[:space:]]*true' "none policy validate true"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/policy-provider/evaluate" "${REQUEST_FIXTURES_DIR}/policy-evaluate-invalid.json" "" "${TMPDIR_LOCAL}/none-policy-invalid.json")"
  assert_status "${status}" "400" "none policy invalid request"

  start_port_forward epydios-oss-evidence-provider "${LOCAL_PORT_EVIDENCE_NONE}" 8080
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/healthz" "" "" "${TMPDIR_LOCAL}/none-evidence-health.json")"
  assert_status "${status}" "200" "none evidence health"
  status="$(request_with_opts GET "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/v1alpha1/capabilities" "" "" "${TMPDIR_LOCAL}/none-evidence-capabilities.json")"
  assert_status "${status}" "200" "none evidence capabilities"
  assert_contains "${TMPDIR_LOCAL}/none-evidence-capabilities.json" '"providerType"[[:space:]]*:[[:space:]]*"EvidenceProvider"' "none evidence provider type"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/v1alpha1/evidence-provider/record" "${REQUEST_FIXTURES_DIR}/evidence-record.json" "" "${TMPDIR_LOCAL}/none-evidence-record.json")"
  assert_status "${status}" "200" "none evidence record"
  assert_contains "${TMPDIR_LOCAL}/none-evidence-record.json" '"accepted"[[:space:]]*:[[:space:]]*true' "none evidence accepted"
  evidence_id="$(extract_json_string "${TMPDIR_LOCAL}/none-evidence-record.json" evidenceId)"
  if [ -z "${evidence_id}" ]; then
    echo "Failed to parse evidenceId from none evidence record response" >&2
    cat "${TMPDIR_LOCAL}/none-evidence-record.json" >&2
    return 1
  fi
  sed "s/__EVIDENCE_ID__/${evidence_id}/g" \
    "${REQUEST_FIXTURES_DIR}/evidence-finalize-bundle.template.json" >"${TMPDIR_LOCAL}/none-evidence-finalize.json"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/v1alpha1/evidence-provider/finalize-bundle" "${TMPDIR_LOCAL}/none-evidence-finalize.json" "" "${TMPDIR_LOCAL}/none-evidence-finalize.out.json")"
  assert_status "${status}" "200" "none evidence finalize"
  assert_contains "${TMPDIR_LOCAL}/none-evidence-finalize.out.json" '"itemCount"[[:space:]]*:[[:space:]]*1' "none evidence finalize item count"
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/v1alpha1/evidence-provider/finalize-bundle" "${REQUEST_FIXTURES_DIR}/evidence-finalize-invalid.json" "" "${TMPDIR_LOCAL}/none-evidence-invalid.json")"
  assert_status "${status}" "400" "none evidence invalid request"

  echo "auth.mode=None provider conformance passed."
}

run_bearer_mode_conformance() {
  local status
  echo "Running auth.mode=BearerTokenSecret provider conformance checks..."

  apply_bearer_fixtures

  start_port_forward oss-profile-static-resolver "${LOCAL_PORT_PROFILE_NONE}" 8080
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_PROFILE_NONE}/v1alpha1/profile-resolver/resolve" "${REQUEST_FIXTURES_DIR}/profile-resolve.json" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/bearer-profile-resolve.json")"
  assert_status "${status}" "200" "bearer profile resolve"

  start_port_forward epydios-oss-policy-provider "${LOCAL_PORT_POLICY_NONE}" 8080
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_POLICY_NONE}/v1alpha1/policy-provider/evaluate" "${REQUEST_FIXTURES_DIR}/policy-evaluate-allow.json" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/bearer-policy-evaluate.json")"
  assert_status "${status}" "200" "bearer policy evaluate"
  assert_contains "${TMPDIR_LOCAL}/bearer-policy-evaluate.json" '"decision"[[:space:]]*:[[:space:]]*"ALLOW"' "bearer policy decision"

  start_port_forward epydios-oss-evidence-provider "${LOCAL_PORT_EVIDENCE_NONE}" 8080
  status="$(request_with_opts POST "http://127.0.0.1:${LOCAL_PORT_EVIDENCE_NONE}/v1alpha1/evidence-provider/record" "${REQUEST_FIXTURES_DIR}/evidence-record.json" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/bearer-evidence-record.json")"
  assert_status "${status}" "200" "bearer evidence record"
  assert_contains "${TMPDIR_LOCAL}/bearer-evidence-record.json" '"accepted"[[:space:]]*:[[:space:]]*true' "bearer evidence accepted"

  echo "auth.mode=BearerTokenSecret provider conformance passed."
}

run_mtls_mode_conformance() {
  local status evidence_id
  local profile_host policy_host evidence_host
  profile_host="m10-mtls-profile-provider.epydios-system.svc.cluster.local"
  policy_host="m10-mtls-policy-provider.epydios-system.svc.cluster.local"
  evidence_host="m10-mtls-bearer-evidence-provider.epydios-system.svc.cluster.local"

  echo "Running auth.mode=MTLS and MTLSAndBearerTokenSecret provider conformance checks..."
  apply_mtls_fixtures

  start_port_forward m10-mtls-profile-provider "${LOCAL_PORT_MTLS_PROFILE}" 8443
  status="$(request_with_opts GET "https://${profile_host}:${LOCAL_PORT_MTLS_PROFILE}/healthz" "" "" "${TMPDIR_LOCAL}/mtls-profile-health.json" "${MTLS_CURL_OPTS[@]}" --resolve "${profile_host}:${LOCAL_PORT_MTLS_PROFILE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls profile health"
  status="$(request_with_opts GET "https://${profile_host}:${LOCAL_PORT_MTLS_PROFILE}/v1alpha1/capabilities" "" "" "${TMPDIR_LOCAL}/mtls-profile-capabilities.json" "${MTLS_CURL_OPTS[@]}" --resolve "${profile_host}:${LOCAL_PORT_MTLS_PROFILE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls profile capabilities"
  assert_contains "${TMPDIR_LOCAL}/mtls-profile-capabilities.json" '"providerType"[[:space:]]*:[[:space:]]*"ProfileResolver"' "mtls profile provider type"
  status="$(request_with_opts POST "https://${profile_host}:${LOCAL_PORT_MTLS_PROFILE}/v1alpha1/profile-resolver/resolve" "${REQUEST_FIXTURES_DIR}/profile-resolve.json" "" "${TMPDIR_LOCAL}/mtls-profile-resolve.json" "${MTLS_CURL_OPTS[@]}" --resolve "${profile_host}:${LOCAL_PORT_MTLS_PROFILE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls profile resolve"
  status="$(request_with_opts GET "https://${profile_host}:${LOCAL_PORT_MTLS_PROFILE}/healthz" "" "" "${TMPDIR_LOCAL}/mtls-profile-no-cert.json" --cacert "${TMPDIR_LOCAL}/ca.crt" --resolve "${profile_host}:${LOCAL_PORT_MTLS_PROFILE}:127.0.0.1")"
  assert_not_status "${status}" "200" "mtls profile no-cert denied"

  start_port_forward m10-mtls-policy-provider "${LOCAL_PORT_MTLS_POLICY}" 8443
  status="$(request_with_opts GET "https://${policy_host}:${LOCAL_PORT_MTLS_POLICY}/healthz" "" "" "${TMPDIR_LOCAL}/mtls-policy-health.json" "${MTLS_CURL_OPTS[@]}" --resolve "${policy_host}:${LOCAL_PORT_MTLS_POLICY}:127.0.0.1")"
  assert_status "${status}" "200" "mtls policy health"
  status="$(request_with_opts POST "https://${policy_host}:${LOCAL_PORT_MTLS_POLICY}/v1alpha1/policy-provider/evaluate" "${REQUEST_FIXTURES_DIR}/policy-evaluate-allow.json" "" "${TMPDIR_LOCAL}/mtls-policy-allow.json" "${MTLS_CURL_OPTS[@]}" --resolve "${policy_host}:${LOCAL_PORT_MTLS_POLICY}:127.0.0.1")"
  assert_status "${status}" "200" "mtls policy evaluate"
  assert_contains "${TMPDIR_LOCAL}/mtls-policy-allow.json" '"decision"[[:space:]]*:[[:space:]]*"ALLOW"' "mtls policy allow decision"
  status="$(request_with_opts POST "https://${policy_host}:${LOCAL_PORT_MTLS_POLICY}/v1alpha1/policy-provider/validate-bundle" "${REQUEST_FIXTURES_DIR}/policy-validate-bundle.json" "" "${TMPDIR_LOCAL}/mtls-policy-validate.json" "${MTLS_CURL_OPTS[@]}" --resolve "${policy_host}:${LOCAL_PORT_MTLS_POLICY}:127.0.0.1")"
  assert_status "${status}" "200" "mtls policy validate"
  assert_contains "${TMPDIR_LOCAL}/mtls-policy-validate.json" '"valid"[[:space:]]*:[[:space:]]*true' "mtls policy validate true"
  status="$(request_with_opts GET "https://${policy_host}:${LOCAL_PORT_MTLS_POLICY}/healthz" "" "" "${TMPDIR_LOCAL}/mtls-policy-no-cert.json" --cacert "${TMPDIR_LOCAL}/ca.crt" --resolve "${policy_host}:${LOCAL_PORT_MTLS_POLICY}:127.0.0.1")"
  assert_not_status "${status}" "200" "mtls policy no-cert denied"

  start_port_forward m10-mtls-bearer-evidence-provider "${LOCAL_PORT_MTLS_EVIDENCE}" 8443
  status="$(request_with_opts GET "https://${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}/healthz" "" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/mtls-evidence-health.json" "${MTLS_CURL_OPTS[@]}" --resolve "${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls+bearer evidence health"
  status="$(request_with_opts POST "https://${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}/v1alpha1/evidence-provider/record" "${REQUEST_FIXTURES_DIR}/evidence-record.json" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/mtls-evidence-record.json" "${MTLS_CURL_OPTS[@]}" --resolve "${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls+bearer evidence record"
  assert_contains "${TMPDIR_LOCAL}/mtls-evidence-record.json" '"accepted"[[:space:]]*:[[:space:]]*true' "mtls+bearer evidence accepted"
  evidence_id="$(extract_json_string "${TMPDIR_LOCAL}/mtls-evidence-record.json" evidenceId)"
  if [ -z "${evidence_id}" ]; then
    echo "Failed to parse evidenceId from mTLS evidence record response" >&2
    cat "${TMPDIR_LOCAL}/mtls-evidence-record.json" >&2
    return 1
  fi
  sed "s/__EVIDENCE_ID__/${evidence_id}/g" \
    "${REQUEST_FIXTURES_DIR}/evidence-finalize-bundle.template.json" >"${TMPDIR_LOCAL}/mtls-evidence-finalize.json"
  status="$(request_with_opts POST "https://${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}/v1alpha1/evidence-provider/finalize-bundle" "${TMPDIR_LOCAL}/mtls-evidence-finalize.json" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/mtls-evidence-finalize.out.json" "${MTLS_CURL_OPTS[@]}" --resolve "${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}:127.0.0.1")"
  assert_status "${status}" "200" "mtls+bearer evidence finalize"
  assert_contains "${TMPDIR_LOCAL}/mtls-evidence-finalize.out.json" '"itemCount"[[:space:]]*:[[:space:]]*1' "mtls+bearer evidence item count"
  status="$(request_with_opts GET "https://${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}/healthz" "" "" "${TMPDIR_LOCAL}/mtls-evidence-missing-bearer.out" "${MTLS_CURL_OPTS[@]}" --resolve "${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}:127.0.0.1")"
  assert_status "${status}" "401" "mtls+bearer missing bearer denied"
  assert_contains "${TMPDIR_LOCAL}/mtls-evidence-missing-bearer.out" 'invalid bearer token' "mtls+bearer missing bearer message"
  status="$(request_with_opts GET "https://${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}/healthz" "" "${TOKEN_VALUE}" "${TMPDIR_LOCAL}/mtls-evidence-no-cert.json" --cacert "${TMPDIR_LOCAL}/ca.crt" --resolve "${evidence_host}:${LOCAL_PORT_MTLS_EVIDENCE}:127.0.0.1")"
  assert_not_status "${status}" "200" "mtls+bearer no-cert denied"

  echo "auth.mode=MTLS and auth.mode=MTLSAndBearerTokenSecret provider conformance passed."
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd grep
  require_cmd sed
  require_cmd awk
  require_cmd openssl
  if [ "${RUN_IMAGE_PREP}" = "1" ] || [ "${RUN_M5_IMAGE_PREP}" = "1" ]; then
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
  prepare_images_if_requested
  apply_base_manifests

  run_none_mode_conformance
  run_bearer_mode_conformance
  run_mtls_mode_conformance

  echo "M10.1 provider conformance passed (ProfileResolver + PolicyProvider + EvidenceProvider across None/BearerTokenSecret/MTLS/MTLSAndBearerTokenSecret with negative checks)."
}

main "$@"
