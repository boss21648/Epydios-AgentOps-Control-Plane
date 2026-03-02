#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"

RUN_M5_BASELINE="${RUN_M5_BASELINE:-1}"
RUN_M5_BOOTSTRAP="${RUN_M5_BOOTSTRAP:-0}"
RUN_M5_IMAGE_PREP="${RUN_M5_IMAGE_PREP:-0}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
LOCAL_PORT="${LOCAL_PORT:-18142}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-3}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"

AIMXS_SKU_FEATURES_JSON="${AIMXS_SKU_FEATURES_JSON:-{\"enterprise\":[\"policy.evaluate\",\"audit.bundle.finalize\"],\"customer\":[\"policy.evaluate\"]}}"

PORT_FORWARD_PID=""
TMPDIR_LOCAL="$(mktemp -d)"
RUNTIME_ENV_PATCHED="0"
MODE_APPLIED="0"
declare -a CURL_TIMEOUT_ARGS
CURL_TIMEOUT_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_MAX_TIME_SECONDS}")

dump_diagnostics() {
  echo
  echo "=== M10.6 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get extensionprovider,deploy,svc,pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment/orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" get extensionprovider aimxs-policy-primary -o yaml >&2 || true
  kubectl -n "${NAMESPACE}" logs deployment/orchestration-runtime -c runtime --tail=200 >&2 || true
}

stop_port_forward() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  PORT_FORWARD_PID=""
}

restore_runtime_entitlement_env() {
  if [ "${RUNTIME_ENV_PATCHED}" != "1" ]; then
    return 0
  fi
  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime \
    AUTHZ_REQUIRE_AIMXS_ENTITLEMENT=false \
    AUTHZ_AIMXS_PROVIDER_PREFIXES- \
    AUTHZ_AIMXS_ALLOWED_SKUS- \
    AUTHZ_AIMXS_REQUIRED_FEATURES- \
    AUTHZ_AIMXS_SKU_FEATURES_JSON- \
    AUTHZ_AIMXS_ENTITLEMENT_TOKEN_REQUIRED=true >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deployment/orchestration-runtime --timeout=8m >/dev/null 2>&1 || true
  RUNTIME_ENV_PATCHED="0"
}

restore_oss_mode() {
  if [ "${MODE_APPLIED}" != "1" ]; then
    return 0
  fi
  kubectl apply -k "${REPO_ROOT}/platform/modes/oss-only" >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete extensionprovider aimxs-policy-primary --ignore-not-found >/dev/null 2>&1 || true
  MODE_APPLIED="0"
}

cleanup() {
  stop_port_forward
  restore_runtime_entitlement_env
  if [ "${KEEP_RESOURCES}" != "1" ]; then
    restore_oss_mode
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

wait_for_provider_ready() {
  local provider="$1"
  local expected_provider_id="${2:-}"
  local start statuses provider_id
  start="$(date +%s)"
  while true; do
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    provider_id="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" \
        -o jsonpath='{.status.resolved.providerId}' 2>/dev/null || true
    )"
    if printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'; then
      if [ -z "${expected_provider_id}" ] || [ "${provider_id}" = "${expected_provider_id}" ]; then
        return 0
      fi
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider ${provider} Ready/Probed." >&2
      echo "statuses=${statuses}" >&2
      echo "resolved.providerId=${provider_id}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

wait_for_runtime_rollout() {
  kubectl -n "${NAMESPACE}" rollout status deployment/orchestration-runtime --timeout=8m >/dev/null
}

ensure_m5_baseline_if_requested() {
  if [ "${RUN_M5_BASELINE}" != "1" ]; then
    return 0
  fi
  echo "Running M5 baseline before M10.6 entitlement gate..."
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  NAMESPACE="${NAMESPACE}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

cleanup_phase4_secure_fixtures_if_present() {
  kubectl delete -k "${REPO_ROOT}/platform/tests/phase4-secure-mtls" --ignore-not-found >/dev/null 2>&1 || true
}

apply_customer_mode_with_local_override() {
  echo "Applying aimxs-customer-hosted mode for entitlement verification..."
  kubectl apply -k "${REPO_ROOT}/platform/modes/aimxs-customer-hosted" >/dev/null
  MODE_APPLIED="1"

  local auth_mode endpoint_url
  auth_mode="$(kubectl -n "${NAMESPACE}" get extensionprovider aimxs-policy-primary -o jsonpath='{.spec.auth.mode}' 2>/dev/null || true)"
  endpoint_url="$(kubectl -n "${NAMESPACE}" get extensionprovider aimxs-policy-primary -o jsonpath='{.spec.endpoint.url}' 2>/dev/null || true)"
  if [ "${auth_mode}" != "MTLSAndBearerTokenSecret" ]; then
    echo "Expected MTLSAndBearerTokenSecret for aimxs-policy-primary, found '${auth_mode}'." >&2
    return 1
  fi
  if ! printf '%s' "${endpoint_url}" | grep -Eq '^https://'; then
    echo "Expected HTTPS endpoint for aimxs-policy-primary, found '${endpoint_url}'." >&2
    return 1
  fi

  # Local entitlement smoke override:
  # keep AIMXS contract id/selection but route endpoint to in-cluster OSS policy provider.
  cat >"${TMPDIR_LOCAL}/aimxs-local-override.yaml" <<'YAML'
apiVersion: controlplane.epydios.ai/v1alpha1
kind: ExtensionProvider
metadata:
  name: aimxs-policy-primary
spec:
  providerType: PolicyProvider
  providerId: aimxs-policy-primary
  contractVersion: v1alpha1
  endpoint:
    url: http://epydios-oss-policy-provider.epydios-system.svc.cluster.local:8080
    healthPath: /healthz
    capabilitiesPath: /v1alpha1/capabilities
    timeoutSeconds: 5
  auth:
    mode: None
  selection:
    enabled: true
    priority: 900
  advertisedCapabilities:
    - policy.evaluate
    - policy.validate_bundle
YAML
  kubectl -n "${NAMESPACE}" apply -f "${TMPDIR_LOCAL}/aimxs-local-override.yaml" >/dev/null

  wait_for_provider_ready oss-policy-opa oss-policy-opa
  wait_for_provider_ready aimxs-policy-primary
}

enable_runtime_entitlement_enforcement() {
  echo "Enabling runtime AIMXS entitlement enforcement..."
  kubectl -n "${NAMESPACE}" set env deployment/orchestration-runtime \
    AUTHZ_REQUIRE_AIMXS_ENTITLEMENT=true \
    AUTHZ_AIMXS_PROVIDER_PREFIXES=aimxs- \
    AUTHZ_AIMXS_ALLOWED_SKUS=enterprise,customer \
    AUTHZ_AIMXS_REQUIRED_FEATURES=policy.evaluate \
    "AUTHZ_AIMXS_SKU_FEATURES_JSON=${AIMXS_SKU_FEATURES_JSON}" \
    AUTHZ_AIMXS_ENTITLEMENT_TOKEN_REQUIRED=true >/dev/null
  RUNTIME_ENV_PATCHED="1"
  wait_for_runtime_rollout
}

start_port_forward() {
  stop_port_forward
  kubectl -n "${NAMESPACE}" port-forward svc/orchestration-runtime "${LOCAL_PORT}:8080" >"${TMPDIR_LOCAL}/port-forward.log" 2>&1 &
  PORT_FORWARD_PID=$!

  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "${CURL_TIMEOUT_ARGS[@]}" "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timed out waiting for runtime port-forward readiness." >&2
      cat "${TMPDIR_LOCAL}/port-forward.log" >&2 || true
      return 1
    fi
    sleep 1
  done
}

write_run_request() {
  local request_id="$1"
  local sku="$2"
  local token="$3"
  local features_json="$4"
  local out_file="$5"

  cat >"${out_file}" <<JSON
{
  "meta": {
    "requestId": "${request_id}",
    "timestamp": "2026-03-02T00:00:00Z",
    "tenantId": "demo-tenant",
    "projectId": "mlops-dev",
    "environment": "dev"
  },
  "subject": {
    "type": "user",
    "id": "m10-entitlement-user"
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
  "mode": "enforce",
  "annotations": {
    "aimxsEntitlement": {
      "sku": "${sku}",
      "token": "${token}",
      "features": ${features_json}
    }
  }
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

assert_run_outcome() {
  local label="$1"
  local request_file="$2"
  local expected_decision="$3"
  local expected_pattern="${4:-}"
  local out_file status attempt
  out_file="${TMPDIR_LOCAL}/${label}.out.json"

  for attempt in $(seq 1 25); do
    status="$(post_json_status "${request_file}" "${out_file}" || true)"
    if [ "${status}" = "201" ] \
      && grep -Eq "\"selectedPolicyProvider\"[[:space:]]*:[[:space:]]*\"aimxs-policy-primary\"" "${out_file}" \
      && grep -Eq "\"policyDecision\"[[:space:]]*:[[:space:]]*\"${expected_decision}\"" "${out_file}"; then
      if [ -z "${expected_pattern}" ] || grep -Eq "${expected_pattern}" "${out_file}"; then
        echo "M10.6 ${label} passed (decision=${expected_decision})."
        return 0
      fi
    fi
    sleep 2
  done

  echo "M10.6 ${label} failed to observe expected decision/pattern." >&2
  echo "Last status=${status}" >&2
  cat "${out_file}" >&2 || true
  return 1
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd grep

  case "${RUNTIME}" in
    kind) require_cmd kind ;;
    k3d) require_cmd k3d ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac

  ensure_m5_baseline_if_requested
  cleanup_phase4_secure_fixtures_if_present
  apply_customer_mode_with_local_override
  enable_runtime_entitlement_enforcement
  start_port_forward

  write_run_request "m10-6-missing-token-$(date +%s)" "enterprise" "" "[\"policy.evaluate\",\"audit.bundle.finalize\"]" "${TMPDIR_LOCAL}/missing-token.json"
  write_run_request "m10-6-unlicensed-sku-$(date +%s)" "trial" "token-trial" "[\"policy.evaluate\",\"audit.bundle.finalize\"]" "${TMPDIR_LOCAL}/unlicensed-sku.json"
  write_run_request "m10-6-missing-feature-$(date +%s)" "enterprise" "token-enterprise" "[\"policy.evaluate\"]" "${TMPDIR_LOCAL}/missing-feature.json"
  write_run_request "m10-6-valid-license-$(date +%s)" "enterprise" "token-enterprise" "[\"policy.evaluate\",\"audit.bundle.finalize\"]" "${TMPDIR_LOCAL}/valid-license.json"

  assert_run_outcome "deny-missing-token" "${TMPDIR_LOCAL}/missing-token.json" "DENY" "AIMXS_ENTITLEMENT_TOKEN_REQUIRED"
  assert_run_outcome "deny-unlicensed-sku" "${TMPDIR_LOCAL}/unlicensed-sku.json" "DENY" "AIMXS_ENTITLEMENT_SKU_NOT_ALLOWED"
  assert_run_outcome "deny-missing-feature" "${TMPDIR_LOCAL}/missing-feature.json" "DENY" "AIMXS_ENTITLEMENT_FEATURE_MISSING"
  assert_run_outcome "allow-valid-license" "${TMPDIR_LOCAL}/valid-license.json" "ALLOW"

  echo "M10.6 entitlement boundary smoke passed (missing token + bad SKU + missing feature => DENY; licensed request => ALLOW)."
}

main "$@"
