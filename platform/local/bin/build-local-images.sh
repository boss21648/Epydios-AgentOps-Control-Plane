#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCKERFILE="${REPO_ROOT}/build/docker/Dockerfile.go-binary"

IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
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

docker_build_cmd() {
  if [ -n "${DOCKER_PLATFORM}" ]; then
    docker build --platform "${DOCKER_PLATFORM}" "$@"
  else
    docker build "$@"
  fi
}

build_image() {
  local image="$1"
  local binary_package="$2"
  echo "Building ${image} from ${binary_package}"
  docker_build_cmd \
    -f "${DOCKERFILE}" \
    --build-arg "BINARY_PACKAGE=${binary_package}" \
    -t "${image}" \
    "${REPO_ROOT}"
}

main() {
  require_cmd docker

  build_image "${CONTROLLER_IMAGE}" "./cmd/extension-provider-registry-controller"
  build_image "${PROFILE_RESOLVER_IMAGE}" "./cmd/profile-resolver-provider"
  build_image "${RUNTIME_ORCHESTRATOR_IMAGE}" "./cmd/control-plane-runtime"
  if [ "${INCLUDE_POLICY_PROVIDER}" = "1" ]; then
    build_image "${POLICY_PROVIDER_IMAGE}" "./cmd/policy-provider-opa-adapter"
  fi
  if [ "${INCLUDE_EVIDENCE_PROVIDER}" = "1" ]; then
    build_image "${EVIDENCE_PROVIDER_IMAGE}" "./cmd/evidence-provider-memory"
  fi
  if [ "${INCLUDE_MTLS_PROVIDER}" = "1" ]; then
    build_image "${MTLS_PROVIDER_IMAGE}" "./cmd/mtls-capabilities-provider"
  fi

  echo
  echo "Built local images:"
  echo "  ${CONTROLLER_IMAGE}"
  echo "  ${PROFILE_RESOLVER_IMAGE}"
  echo "  ${RUNTIME_ORCHESTRATOR_IMAGE}"
  if [ "${INCLUDE_POLICY_PROVIDER}" = "1" ]; then
    echo "  ${POLICY_PROVIDER_IMAGE}"
  fi
  if [ "${INCLUDE_EVIDENCE_PROVIDER}" = "1" ]; then
    echo "  ${EVIDENCE_PROVIDER_IMAGE}"
  fi
  if [ "${INCLUDE_MTLS_PROVIDER}" = "1" ]; then
    echo "  ${MTLS_PROVIDER_IMAGE}"
  fi
}

main "$@"
