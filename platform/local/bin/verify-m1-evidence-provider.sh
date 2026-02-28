#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-kind}"                # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
RUN_M1_POLICY="${RUN_M1_POLICY:-1}"       # run the policy-provider gate first
RUN_M0="${RUN_M0:-1}"                     # passed through when RUN_M1_POLICY=1 or used directly
RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP:-1}" # passed through to verify-m0

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kubectl
  require_cmd docker
  require_cmd curl
  if [ "${RUNTIME}" = "kind" ]; then
    require_cmd kind
  elif [ "${RUNTIME}" = "k3d" ]; then
    require_cmd k3d
  else
    echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)" >&2
    exit 1
  fi

  if [ "${RUN_M1_POLICY}" = "1" ]; then
    echo "Running M1 policy-provider gate first..."
    RUNTIME="${RUNTIME}" CLUSTER_NAME="${CLUSTER_NAME}" RUN_M0="${RUN_M0}" RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
      "${SCRIPT_DIR}/verify-m1-policy-provider.sh"
  elif [ "${RUN_M0}" = "1" ]; then
    echo "Running M0 gate first..."
    RUNTIME="${RUNTIME}" CLUSTER_NAME="${CLUSTER_NAME}" RUN_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
      "${SCRIPT_DIR}/verify-m0.sh"
  fi

  echo
  echo "Building/loading evidence provider image..."
  INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/build-local-images.sh"

  if [ "${RUNTIME}" = "kind" ]; then
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-kind.sh"
  else
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_EVIDENCE_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-k3d.sh"
  fi

  echo
  echo "Running evidence provider smoke..."
  "${SCRIPT_DIR}/smoke-evidence-provider-memory.sh"

  echo
  echo "Evidence provider verification passed."
}

main "$@"

