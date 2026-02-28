#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-kind}"                # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
RUN_M0="${RUN_M0:-0}"                     # optional: run M0 gate first
RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP:-0}" # optional: rerun bootstrap if RUN_M0=1
NAMESPACE="${NAMESPACE:-epydios-system}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kubectl
  if [ "${RUNTIME}" = "kind" ]; then
    require_cmd kind
  elif [ "${RUNTIME}" = "k3d" ]; then
    require_cmd k3d
  else
    echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)" >&2
    exit 1
  fi

  if [ "${RUN_M0}" = "1" ]; then
    echo "Running M0 gate first..."
    RUNTIME="${RUNTIME}" CLUSTER_NAME="${CLUSTER_NAME}" RUN_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
      "${SCRIPT_DIR}/verify-m0.sh"
  fi

  kubectl -n "${NAMESPACE}" wait \
    --for=condition=Available deployment/extension-provider-registry-controller \
    --timeout=6m

  # Verifier always cleans negative fixtures on exit.
  KEEP_RESOURCES=0 NAMESPACE="${NAMESPACE}" "${SCRIPT_DIR}/smoke-provider-discovery-negative.sh"
}

main "$@"
