#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
PROVIDER_NAME="${PROVIDER_NAME:-oss-profile-static}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait \
    --for=condition=Available \
    "deployment/${name}" \
    --timeout=5m
}

print_provider_status() {
  kubectl -n "${NAMESPACE}" get extensionprovider "${PROVIDER_NAME}" -o yaml || true
}

wait_for_provider_probe() {
  local start
  start="$(date +%s)"

  while true; do
    local statuses ready probed provider_id
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${PROVIDER_NAME}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true
    )"
    ready="$(printf '%s\n' "${statuses}" | awk -F= '$1=="Ready"{print $2; exit}')"
    probed="$(printf '%s\n' "${statuses}" | awk -F= '$1=="Probed"{print $2; exit}')"
    provider_id="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${PROVIDER_NAME}" \
        -o jsonpath='{.status.resolved.providerId}' 2>/dev/null || true
    )"

    if [ "${ready}" = "True" ] && [ "${probed}" = "True" ]; then
      echo "Provider discovery smoke passed: ${PROVIDER_NAME} (resolved.providerId=${provider_id:-<empty>})"
      return 0
    fi

    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider discovery to succeed for ${PROVIDER_NAME}" >&2
      print_provider_status >&2
      return 1
    fi

    sleep 2
  done
}

main() {
  require_cmd kubectl

  kubectl apply -k "${REPO_ROOT}/platform/system"

  wait_for_deployment extension-provider-registry-controller
  wait_for_deployment oss-profile-static-resolver
  wait_for_provider_probe
}

main "$@"

