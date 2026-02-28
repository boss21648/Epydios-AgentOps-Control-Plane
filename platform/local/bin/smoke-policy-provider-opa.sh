#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-15}"

PORT_FORWARD_PID=""
TMPDIR_LOCAL="$(mktemp -d)"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

cleanup() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPDIR_LOCAL}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

print_deployment_diagnostics() {
  local name="$1"
  local selector="app.kubernetes.io/name=${name}"
  local pod_name

  echo "=== M1 diagnostics: deployment/${name} (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deployment "${name}" -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get rs,pods -l "${selector}" -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment "${name}" >&2 || true

  pod_name="$(kubectl -n "${NAMESPACE}" get pod -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod_name}" ]; then
    echo "--- describe pod/${pod_name} ---" >&2
    kubectl -n "${NAMESPACE}" describe pod "${pod_name}" >&2 || true

    echo "--- logs pod/${pod_name} container=policy-provider ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c policy-provider --tail=200 >&2 || true
    echo "--- logs pod/${pod_name} container=opa ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c opa --tail=200 >&2 || true

    echo "--- previous logs pod/${pod_name} container=policy-provider (if any) ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c policy-provider --previous --tail=200 >&2 || true
    echo "--- previous logs pod/${pod_name} container=opa (if any) ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c opa --previous --tail=200 >&2 || true
  fi
}

wait_for_deployment() {
  local name="$1"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout=8m; then
    print_deployment_diagnostics "${name}"
    return 1
  fi
}

wait_for_provider_status() {
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

start_port_forward() {
  kubectl -n "${NAMESPACE}" port-forward svc/epydios-oss-policy-provider "${LOCAL_PORT}:8080" \
    >"${TMPDIR_LOCAL}/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!

  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "${CURL_TIMEOUT_ARGS[@]}" "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for port-forward to become ready" >&2
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
    "requestId": "m1-allow-001",
    "timestamp": "2026-02-26T00:00:00Z",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "dev"
  },
  "subject": {
    "type": "user",
    "id": "alice"
  },
  "action": {
    "verb": "read",
    "target": "task"
  },
  "resource": {
    "kind": "Task",
    "namespace": "epydios-system",
    "name": "demo-task"
  },
  "mode": "enforce"
}
JSON

  cat >"${TMPDIR_LOCAL}/deny.json" <<'JSON'
{
  "meta": {
    "requestId": "m1-deny-001",
    "timestamp": "2026-02-26T00:00:00Z",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "prod"
  },
  "subject": {
    "type": "user",
    "id": "alice",
    "attributes": {
      "approvedForProd": false
    }
  },
  "action": {
    "verb": "delete",
    "target": "task"
  },
  "resource": {
    "kind": "Task",
    "namespace": "epydios-system",
    "name": "demo-task"
  },
  "mode": "enforce"
}
JSON

  cat >"${TMPDIR_LOCAL}/validate.json" <<'JSON'
{
  "meta": {
    "requestId": "m1-validate-001",
    "timestamp": "2026-02-26T00:00:00Z"
  },
  "bundle": {
    "policyId": "EPYDIOS_OSS_POLICY_BASELINE",
    "policyVersion": "v1"
  },
  "expectedCapabilities": [
    "policy.evaluate",
    "policy.validate_bundle"
  ]
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

main() {
  require_cmd kubectl
  require_cmd curl

  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-policy-opa"

  wait_for_deployment epydios-oss-policy-provider
  wait_for_provider_status oss-policy-opa

  write_requests
  start_port_forward

  post_json "/v1alpha1/policy-provider/evaluate" "${TMPDIR_LOCAL}/allow.json" "${TMPDIR_LOCAL}/allow.out.json"
  post_json "/v1alpha1/policy-provider/evaluate" "${TMPDIR_LOCAL}/deny.json" "${TMPDIR_LOCAL}/deny.out.json"
  post_json "/v1alpha1/policy-provider/validate-bundle" "${TMPDIR_LOCAL}/validate.json" "${TMPDIR_LOCAL}/validate.out.json"

  assert_response_contains "${TMPDIR_LOCAL}/allow.out.json" '"decision"[[:space:]]*:[[:space:]]*"ALLOW"' "allow decision"
  assert_response_contains "${TMPDIR_LOCAL}/deny.out.json" '"decision"[[:space:]]*:[[:space:]]*"DENY"' "deny decision"
  assert_response_contains "${TMPDIR_LOCAL}/validate.out.json" '"valid"[[:space:]]*:[[:space:]]*true' "validate-bundle"

  echo "M1 policy provider smoke passed (ALLOW + DENY + validate-bundle)."
}

main "$@"
