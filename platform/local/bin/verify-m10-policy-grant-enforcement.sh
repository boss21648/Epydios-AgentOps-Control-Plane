#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"

RUN_M5_BASELINE="${RUN_M5_BASELINE:-1}"
RUN_M5_BOOTSTRAP="${RUN_M5_BOOTSTRAP:-1}"
RUN_M5_IMAGE_PREP="${RUN_M5_IMAGE_PREP:-1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
LOCAL_PORT="${LOCAL_PORT:-18096}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"

PORT_FORWARD_PID=""
TMPDIR_LOCAL="$(mktemp -d)"
RUNTIME_ENV_PATCHED="0"
NO_GRANT_POLICY_APPLIED="0"
POLICY_SELECTION_PATCHED="0"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== M10.3 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deploy,svc,pods,configmap,extensionprovider -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/epydios-oss-policy-provider >&2 || true
  kubectl -n "${NAMESPACE}" logs deployment/orchestration-runtime -c runtime --tail=120 >&2 || true
  kubectl -n "${NAMESPACE}" logs deployment/epydios-oss-policy-provider -c policy-provider --tail=120 >&2 || true
  kubectl -n "${NAMESPACE}" logs deployment/epydios-oss-policy-provider -c opa --tail=120 >&2 || true
}

stop_port_forward() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  PORT_FORWARD_PID=""
}

restore_runtime_env() {
  if [ "${RUNTIME_ENV_PATCHED}" != "1" ]; then
    return 0
  fi
  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime AUTHZ_REQUIRE_POLICY_GRANT=false >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deployment/orchestration-runtime --timeout=6m >/dev/null 2>&1 || true
  RUNTIME_ENV_PATCHED="0"
}

restore_policy_config() {
  if [ "${NO_GRANT_POLICY_APPLIED}" != "1" ]; then
    return 0
  fi
  kubectl -n "${NAMESPACE}" apply -f "${REPO_ROOT}/platform/providers/oss-policy-opa/configmap-opa-policy.yaml" >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout restart deployment/epydios-oss-policy-provider >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deployment/epydios-oss-policy-provider --timeout=6m >/dev/null 2>&1 || true
  NO_GRANT_POLICY_APPLIED="0"
}

restore_policy_selection() {
  if [ "${POLICY_SELECTION_PATCHED}" != "1" ]; then
    return 0
  fi
  kubectl -n "${NAMESPACE}" apply -f "${REPO_ROOT}/platform/providers/oss-policy-opa/extensionprovider.yaml" >/dev/null 2>&1 || true
  wait_for_provider_ready_probed oss-policy-opa >/dev/null 2>&1 || true
  POLICY_SELECTION_PATCHED="0"
}

cleanup() {
  stop_port_forward
  restore_policy_config
  restore_policy_selection
  restore_runtime_env
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

wait_for_rollout() {
  local deploy="$1"
  kubectl -n "${NAMESPACE}" rollout status "deployment/${deploy}" --timeout=8m
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

wait_for_baseline_providers_ready() {
  wait_for_provider_ready_probed oss-profile-static
  wait_for_provider_ready_probed oss-policy-opa
  wait_for_provider_ready_probed oss-evidence-memory
}

prioritize_oss_policy_provider() {
  kubectl -n "${NAMESPACE}" patch extensionprovider oss-policy-opa --type merge \
    -p '{"spec":{"selection":{"enabled":true,"priority":1000}}}' >/dev/null
  POLICY_SELECTION_PATCHED="1"
  wait_for_provider_ready_probed oss-policy-opa
}

ensure_m5_baseline_if_requested() {
  if [ "${RUN_M5_BASELINE}" != "1" ]; then
    return 0
  fi
  echo "Running M5 baseline first..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

enable_runtime_grant_requirement() {
  echo "Enabling AUTHZ_REQUIRE_POLICY_GRANT=true on runtime..."
  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime AUTHZ_REQUIRE_POLICY_GRANT=true >/dev/null
  RUNTIME_ENV_PATCHED="1"
  wait_for_rollout orchestration-runtime
}

apply_policy_without_grant() {
  local target="${TMPDIR_LOCAL}/policy-no-grant.yaml"
  cat >"${target}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: epydios-oss-policy-opa-rego
data:
  policy.rego: |
    package epydios.policy

    deny_reasons[r] {
      lower(input.action.verb) == "delete"
      r := {
        "code": "DELETE_DENIED",
        "message": "delete verb is denied by OSS baseline policy"
      }
    }

    deny_reasons[r] {
      lower(object.get(input.meta, "environment", "")) == "prod"
      lower(object.get(input, "mode", "enforce")) != "audit"
      lower(object.get(input.subject, "type", "")) == "user"
      attrs := object.get(input.subject, "attributes", {})
      not object.get(attrs, "approvedForProd", false)
      r := {
        "code": "PROD_APPROVAL_REQUIRED",
        "message": "user subject requires approvedForProd=true for prod enforce mode"
      }
    }

    evaluate = resp {
      reasons := [x | deny_reasons[x]]
      count(reasons) > 0
      resp := {
        "decision": "DENY",
        "reasons": reasons,
        "output": {
          "engine": "opa",
          "rule": "deny",
          "reasonCount": count(reasons)
        }
      }
    }

    evaluate = resp {
      reasons := [x | deny_reasons[x]]
      count(reasons) == 0
      resp := {
        "decision": "ALLOW",
        "reasons": [
          {
            "code": "ALLOW_DEFAULT",
            "message": "Allowed by OSS baseline OPA policy."
          }
        ],
        "output": {
          "engine": "opa",
          "rule": "default-allow"
        }
      }
    }
YAML
  kubectl -n "${NAMESPACE}" apply -f "${target}"
  kubectl -n "${NAMESPACE}" rollout restart deployment/epydios-oss-policy-provider >/dev/null
  wait_for_rollout epydios-oss-policy-provider
  wait_for_provider_ready_probed oss-policy-opa
  NO_GRANT_POLICY_APPLIED="1"
}

apply_policy_with_grant() {
  kubectl -n "${NAMESPACE}" apply -f "${REPO_ROOT}/platform/providers/oss-policy-opa/configmap-opa-policy.yaml"
  kubectl -n "${NAMESPACE}" rollout restart deployment/epydios-oss-policy-provider >/dev/null
  wait_for_rollout epydios-oss-policy-provider
  wait_for_provider_ready_probed oss-policy-opa
  NO_GRANT_POLICY_APPLIED="0"
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
      echo "Timed out waiting for runtime port-forward readiness" >&2
      cat "${TMPDIR_LOCAL}/port-forward.log" >&2 || true
      return 1
    fi
    sleep 1
  done
}

write_requests() {
  cat >"${TMPDIR_LOCAL}/allow-no-grant.json" <<'JSON'
{
  "meta": {
    "requestId": "m10-grant-allow-001",
    "timestamp": "2026-02-28T00:00:00Z",
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

  cat >"${TMPDIR_LOCAL}/allow-with-grant.json" <<'JSON'
{
  "meta": {
    "requestId": "m10-grant-allow-002",
    "timestamp": "2026-02-28T00:00:00Z",
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

  cat >"${TMPDIR_LOCAL}/deny-no-grant.json" <<'JSON'
{
  "meta": {
    "requestId": "m10-grant-deny-001",
    "timestamp": "2026-02-28T00:00:00Z",
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

post_json_status() {
  local body_file="$1"
  local out_file="$2"
  curl -sS "${CURL_TIMEOUT_ARGS[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    -o "${out_file}" \
    -w "%{http_code}" \
    "http://127.0.0.1:${LOCAL_PORT}/v1alpha1/runtime/runs" \
    --data-binary @"${body_file}"
}

assert_status() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  local body_file="${4:-}"
  if [ "${actual}" != "${expected}" ]; then
    echo "Assertion failed (${label}): expected status ${expected}, got ${actual}" >&2
    if [ -n "${body_file}" ] && [ -f "${body_file}" ]; then
      echo "--- response body (${label}) ---" >&2
      cat "${body_file}" >&2
    fi
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "${pattern}" "${file}"; then
    echo "Assertion failed (${label}): pattern ${pattern} not found" >&2
    cat "${file}" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq "${pattern}" "${file}"; then
    echo "Assertion failed (${label}): pattern ${pattern} should not be present" >&2
    cat "${file}" >&2
    return 1
  fi
}

wait_for_status() {
  local body_file="$1"
  local out_file="$2"
  local expected="$3"
  local label="$4"
  local timeout="${5:-40}"
  local interval="${6:-2}"
  local start now status
  start="$(date +%s)"
  while true; do
    status="$(post_json_status "${body_file}" "${out_file}")"
    if [ "${status}" = "${expected}" ]; then
      return 0
    fi
    now="$(date +%s)"
    if [ $(( now - start )) -ge "${timeout}" ]; then
      assert_status "${status}" "${expected}" "${label}" "${out_file}"
      return 1
    fi
    sleep "${interval}"
  done
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd sed

  ensure_m5_baseline_if_requested
  enable_runtime_grant_requirement
  prioritize_oss_policy_provider
  wait_for_baseline_providers_ready
  apply_policy_without_grant
  write_requests
  start_port_forward

  echo "Asserting grant-required failure when provider omits token..."
  local status
  status="$(post_json_status "${TMPDIR_LOCAL}/allow-no-grant.json" "${TMPDIR_LOCAL}/allow-no-grant.out.json")"
  assert_status "${status}" "500" "allow without grant returns failure" "${TMPDIR_LOCAL}/allow-no-grant.out.json"
  assert_contains "${TMPDIR_LOCAL}/allow-no-grant.out.json" 'RUN_EXECUTION_FAILED' "allow without grant error code"
  assert_contains "${TMPDIR_LOCAL}/allow-no-grant.out.json" 'missing grant token' "allow without grant error message"

  echo "Asserting DENY path remains executable without grant token..."
  status="$(post_json_status "${TMPDIR_LOCAL}/deny-no-grant.json" "${TMPDIR_LOCAL}/deny-no-grant.out.json")"
  assert_status "${status}" "201" "deny without grant still accepted" "${TMPDIR_LOCAL}/deny-no-grant.out.json"
  assert_contains "${TMPDIR_LOCAL}/deny-no-grant.out.json" '"policyDecision"[[:space:]]*:[[:space:]]*"DENY"' "deny decision still returned"

  echo "Re-applying token-emitting policy and asserting success..."
  apply_policy_with_grant
  wait_for_status "${TMPDIR_LOCAL}/allow-with-grant.json" "${TMPDIR_LOCAL}/allow-with-grant.out.json" "201" "allow with grant succeeds"
  assert_contains "${TMPDIR_LOCAL}/allow-with-grant.out.json" '"status"[[:space:]]*:[[:space:]]*"COMPLETED"' "allow with grant completed"
  assert_contains "${TMPDIR_LOCAL}/allow-with-grant.out.json" '"policyGrantTokenPresent"[[:space:]]*:[[:space:]]*true' "grant presence tracked"
  assert_contains "${TMPDIR_LOCAL}/allow-with-grant.out.json" '"policyGrantTokenSha256"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' "grant hash tracked"
  assert_not_contains "${TMPDIR_LOCAL}/allow-with-grant.out.json" 'oss-grant-m10-grant-allow-002' "raw grant token not leaked in runtime response"

  echo "M10.3 policy grant enforcement passed (no-token blocked, DENY no-token allowed, token-present ALLOW succeeds)."
}

main "$@"
