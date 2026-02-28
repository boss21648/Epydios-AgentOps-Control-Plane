#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-150}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"

cleanup() {
  if [ "${KEEP_RESOURCES}" = "1" ]; then
    return 0
  fi
  kubectl delete -k "${REPO_ROOT}/platform/tests/provider-discovery-negative" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

wait_for_failed_probe() {
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

    if printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'; then
      echo "Negative case failed (unexpected probe success): ${name}" >&2
      echo "statuses=${statuses}" >&2
      echo "error_text=${error_text}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o yaml >&2 || true
      return 1
    fi

    if printf '%s' "${statuses}" | grep -q 'Ready=False' && printf '%s' "${statuses}" | grep -q 'Probed=False'; then
      if printf '%s' "${error_text}" | grep -Eiq "${expected_pattern}"; then
        echo "Negative case passed: ${name} -> ${error_text}"
        return 0
      fi
    fi

    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for negative probe result on ${name}" >&2
      echo "statuses=${statuses}" >&2
      echo "error_text=${error_text}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${name}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

main() {
  require_cmd kubectl
  require_cmd grep

  kubectl apply -k "${REPO_ROOT}/platform/tests/provider-discovery-negative"

  wait_for_failed_probe "negative-bad-endpoint" "health probe request failed|no such host|dial tcp|connection refused"
  wait_for_failed_probe "negative-type-mismatch" "provider type mismatch"
  wait_for_failed_probe "negative-bearer-missing-secret" "read bearer token secret|not found"

  echo "Negative provider-discovery smoke passed (bad endpoint, providerType mismatch, bearer secret failure)."
}

main "$@"
