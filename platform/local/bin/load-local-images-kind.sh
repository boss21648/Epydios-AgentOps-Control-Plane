#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
IMAGE_TAG="${IMAGE_TAG:-0.2.0}"
INCLUDE_POLICY_PROVIDER="${INCLUDE_POLICY_PROVIDER:-0}"
INCLUDE_EVIDENCE_PROVIDER="${INCLUDE_EVIDENCE_PROVIDER:-0}"
INCLUDE_MTLS_PROVIDER="${INCLUDE_MTLS_PROVIDER:-0}"

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/epydios/epydios-extension-provider-registry-controller:${IMAGE_TAG}}"
PROFILE_RESOLVER_IMAGE="${PROFILE_RESOLVER_IMAGE:-ghcr.io/epydios/epydios-oss-profile-static-resolver:${IMAGE_TAG}}"
RUNTIME_ORCHESTRATOR_IMAGE="${RUNTIME_ORCHESTRATOR_IMAGE:-ghcr.io/epydios/epydios-control-plane-runtime:${IMAGE_TAG}}"
POLICY_PROVIDER_IMAGE="${POLICY_PROVIDER_IMAGE:-ghcr.io/epydios/epydios-oss-policy-opa-provider:${IMAGE_TAG}}"
EVIDENCE_PROVIDER_IMAGE="${EVIDENCE_PROVIDER_IMAGE:-ghcr.io/epydios/epydios-oss-evidence-memory-provider:${IMAGE_TAG}}"
MTLS_PROVIDER_IMAGE="${MTLS_PROVIDER_IMAGE:-ghcr.io/epydios/epydios-mtls-capabilities-provider:${IMAGE_TAG}}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kind

  kind load docker-image \
    --name "${CLUSTER_NAME}" \
    "${CONTROLLER_IMAGE}" \
    "${PROFILE_RESOLVER_IMAGE}" \
    "${RUNTIME_ORCHESTRATOR_IMAGE}"

  if [ "${INCLUDE_POLICY_PROVIDER}" = "1" ]; then
    kind load docker-image \
      --name "${CLUSTER_NAME}" \
      "${POLICY_PROVIDER_IMAGE}"
  fi
  if [ "${INCLUDE_EVIDENCE_PROVIDER}" = "1" ]; then
    kind load docker-image \
      --name "${CLUSTER_NAME}" \
      "${EVIDENCE_PROVIDER_IMAGE}"
  fi
  if [ "${INCLUDE_MTLS_PROVIDER}" = "1" ]; then
    kind load docker-image \
      --name "${CLUSTER_NAME}" \
      "${MTLS_PROVIDER_IMAGE}"
  fi

  echo "Loaded images into kind cluster '${CLUSTER_NAME}'."
}

main "$@"
