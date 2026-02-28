#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-kind}"               # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
RUN_M0="${RUN_M0:-1}"                    # 1 runs verify-m0 first
RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP:-1}" # passed through to verify-m0 as RUN_BOOTSTRAP
OPA_SIDECAR_IMAGE="${OPA_SIDECAR_IMAGE:-openpolicyagent/opa:0.67.1}"

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

  if [ "${RUN_M0}" = "1" ]; then
    echo "Running M0 gate first..."
    RUNTIME="${RUNTIME}" CLUSTER_NAME="${CLUSTER_NAME}" RUN_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
      "${SCRIPT_DIR}/verify-m0.sh"
  fi

  echo
  echo "Building/loading M1 policy provider image..."
  INCLUDE_POLICY_PROVIDER=1 "${SCRIPT_DIR}/build-local-images.sh"

  echo "Pulling OPA sidecar image for local cluster preload (${OPA_SIDECAR_IMAGE})..."
  if ! docker pull "${OPA_SIDECAR_IMAGE}"; then
    echo "Warning: failed to pull ${OPA_SIDECAR_IMAGE}; continuing (cluster may pull it directly)." >&2
  fi

  if [ "${RUNTIME}" = "kind" ]; then
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-kind.sh"
    if docker image inspect "${OPA_SIDECAR_IMAGE}" >/dev/null 2>&1; then
      kind load docker-image --name "${CLUSTER_NAME}" "${OPA_SIDECAR_IMAGE}"
    fi
  else
    CLUSTER_NAME="${CLUSTER_NAME}" INCLUDE_POLICY_PROVIDER=1 "${SCRIPT_DIR}/load-local-images-k3d.sh"
    if docker image inspect "${OPA_SIDECAR_IMAGE}" >/dev/null 2>&1; then
      k3d image import --cluster "${CLUSTER_NAME}" "${OPA_SIDECAR_IMAGE}"
    fi
  fi

  echo
  echo "Running M1 policy provider smoke..."
  "${SCRIPT_DIR}/smoke-policy-provider-opa.sh"

  echo
  echo "M1 policy provider verification passed."
}

main "$@"
