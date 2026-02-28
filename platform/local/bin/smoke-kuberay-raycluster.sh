#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-kuberay-smoke}"
RUN_LIVE_APPLY="${RUN_LIVE_APPLY:-0}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"

cleanup() {
  if [ "${RUN_LIVE_APPLY}" != "1" ] || [ "${KEEP_RESOURCES}" = "1" ]; then
    return 0
  fi
  kubectl -n "${NAMESPACE}" delete -k "${REPO_ROOT}/platform/tests/kuberay-smoke" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kubectl

  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl create namespace "${NAMESPACE}" >/dev/null
  fi

  if [ "${RUN_LIVE_APPLY}" = "1" ]; then
    kubectl -n "${NAMESPACE}" apply -k "${REPO_ROOT}/platform/tests/kuberay-smoke" >/dev/null
    kubectl -n "${NAMESPACE}" get raycluster raycluster-smoke >/dev/null
    echo "KubeRay smoke passed (live RayCluster apply)."
    return 0
  fi

  kubectl -n "${NAMESPACE}" apply --dry-run=server -k "${REPO_ROOT}/platform/tests/kuberay-smoke" >/dev/null
  echo "KubeRay smoke passed (server-side RayCluster validation)."
}

main "$@"
