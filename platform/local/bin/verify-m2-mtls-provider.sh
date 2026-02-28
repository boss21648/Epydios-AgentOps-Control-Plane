#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}"                # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
RUN_M1_NEGATIVE="${RUN_M1_NEGATIVE:-0}"   # optional: run M1 negative gate first
RUN_M0="${RUN_M0:-0}"                     # passed through when RUN_M1_NEGATIVE=1
RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP:-0}" # passed through when RUN_M1_NEGATIVE=1

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kubectl
  require_cmd docker
  require_cmd openssl
  if [ "${RUNTIME}" = "kind" ]; then
    require_cmd kind
  elif [ "${RUNTIME}" = "k3d" ]; then
    require_cmd k3d
  else
    echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)" >&2
    exit 1
  fi

  if [ "${RUN_M1_NEGATIVE}" = "1" ]; then
    echo "Running M1 negative-discovery gate first..."
    RUNTIME="${RUNTIME}" CLUSTER_NAME="${CLUSTER_NAME}" RUN_M0="${RUN_M0}" RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
      "${SCRIPT_DIR}/verify-m1-provider-discovery-negative.sh"
  fi

  echo
  echo "Building/loading mTLS fixture provider image..."
  INCLUDE_MTLS_PROVIDER=1 "${SCRIPT_DIR}/build-local-images.sh"

  if [ "${RUNTIME}" = "kind" ]; then
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_MTLS_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-kind.sh"
  else
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_MTLS_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-k3d.sh"
  fi

  echo
  echo "Applying platform/system RBAC/controller manifests and restarting controller..."
  kubectl apply -k "${REPO_ROOT}/platform/system"
  kubectl -n epydios-system rollout restart deployment/extension-provider-registry-controller
  kubectl -n epydios-system rollout status deployment/extension-provider-registry-controller

  echo
  echo "Running mTLS provider discovery smoke..."
  "${SCRIPT_DIR}/smoke-provider-discovery-mtls.sh"

  echo
  echo "M2 mTLS provider verification passed."
}

main "$@"
