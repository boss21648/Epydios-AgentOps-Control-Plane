#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"
LOCAL_PORT="${LOCAL_PORT:-18081}"
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

  echo "=== Evidence diagnostics: deployment/${name} (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deployment "${name}" -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get rs,pods -l "${selector}" -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment "${name}" >&2 || true

  pod_name="$(kubectl -n "${NAMESPACE}" get pod -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod_name}" ]; then
    echo "--- describe pod/${pod_name} ---" >&2
    kubectl -n "${NAMESPACE}" describe pod "${pod_name}" >&2 || true
    echo "--- logs pod/${pod_name} container=evidence-provider ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c evidence-provider --tail=200 >&2 || true
    echo "--- previous logs pod/${pod_name} container=evidence-provider (if any) ---" >&2
    kubectl -n "${NAMESPACE}" logs "${pod_name}" -c evidence-provider --previous --tail=200 >&2 || true
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
  kubectl -n "${NAMESPACE}" port-forward svc/epydios-oss-evidence-provider "${LOCAL_PORT}:8080" \
    >"${TMPDIR_LOCAL}/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!

  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "${CURL_TIMEOUT_ARGS[@]}" "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for evidence provider port-forward to become ready" >&2
      cat "${TMPDIR_LOCAL}/port-forward.log" >&2 || true
      return 1
    fi
    sleep 1
  done
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

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd grep
  require_cmd sed

  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-evidence-memory"

  wait_for_deployment epydios-oss-evidence-provider
  wait_for_provider_status oss-evidence-memory

  start_port_forward

  cat >"${TMPDIR_LOCAL}/record.json" <<'JSON'
{
  "meta": {
    "requestId": "evidence-record-001",
    "timestamp": "2026-02-26T00:00:00Z",
    "tenantId": "demo-tenant",
    "projectId": "demo-project",
    "environment": "dev"
  },
  "eventType": "policy.decision",
  "eventId": "policy-decision-001",
  "runId": "run-evidence-001",
  "stage": "authorize",
  "payload": {
    "decision": "ALLOW"
  },
  "retentionClass": "standard"
}
JSON

  curl -fsS "${CURL_TIMEOUT_ARGS[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    "http://127.0.0.1:${LOCAL_PORT}/v1alpha1/evidence-provider/record" \
    --data-binary @"${TMPDIR_LOCAL}/record.json" \
    >"${TMPDIR_LOCAL}/record.out.json"

  assert_response_contains "${TMPDIR_LOCAL}/record.out.json" '"accepted"[[:space:]]*:[[:space:]]*true' "evidence record accepted"
  assert_response_contains "${TMPDIR_LOCAL}/record.out.json" '"evidenceId"[[:space:]]*:[[:space:]]*"evd_' "evidenceId shape"
  assert_response_contains "${TMPDIR_LOCAL}/record.out.json" '"storageUri"[[:space:]]*:[[:space:]]*"memory://' "storageUri"

  EVIDENCE_ID="$(extract_json_string "${TMPDIR_LOCAL}/record.out.json" evidenceId)"
  if [ -z "${EVIDENCE_ID}" ]; then
    echo "Failed to parse evidenceId from record response" >&2
    cat "${TMPDIR_LOCAL}/record.out.json" >&2
    exit 1
  fi

  cat >"${TMPDIR_LOCAL}/finalize.json" <<JSON
{
  "meta": {
    "requestId": "evidence-finalize-001",
    "timestamp": "2026-02-26T00:00:00Z"
  },
  "bundleId": "bundle-001",
  "runId": "run-evidence-001",
  "evidenceIds": ["${EVIDENCE_ID}"],
  "retentionClass": "standard",
  "annotations": {
    "source": "local-smoke"
  }
}
JSON

  curl -fsS "${CURL_TIMEOUT_ARGS[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    "http://127.0.0.1:${LOCAL_PORT}/v1alpha1/evidence-provider/finalize-bundle" \
    --data-binary @"${TMPDIR_LOCAL}/finalize.json" \
    >"${TMPDIR_LOCAL}/finalize.out.json"

  assert_response_contains "${TMPDIR_LOCAL}/finalize.out.json" '"bundleId"[[:space:]]*:[[:space:]]*"bundle-001"' "bundleId"
  assert_response_contains "${TMPDIR_LOCAL}/finalize.out.json" '"manifestUri"[[:space:]]*:[[:space:]]*"memory://' "manifestUri"
  assert_response_contains "${TMPDIR_LOCAL}/finalize.out.json" '"manifestChecksum"[[:space:]]*:[[:space:]]*"sha256:' "manifestChecksum"
  assert_response_contains "${TMPDIR_LOCAL}/finalize.out.json" '"itemCount"[[:space:]]*:[[:space:]]*1' "itemCount"

  echo "Evidence provider smoke passed (record + finalize-bundle)."
}

main "$@"
