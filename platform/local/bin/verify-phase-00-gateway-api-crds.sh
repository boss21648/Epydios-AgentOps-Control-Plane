#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK_PARENT="$(cd "${REPO_ROOT}/.." && pwd)"

GATEWAY_API_REF="${GATEWAY_API_REF:-1c39c4baddf3a2c91e93c0324f6777d3cf5b0dfe}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-1}"
SUBSTRATE_ROOT="${SUBSTRATE_ROOT:-${WORK_PARENT}/SUBSTRATE_UPSTREAMS}"
CRD_WAIT_TIMEOUT="${CRD_WAIT_TIMEOUT:-5m}"

TMPDIR_LOCAL="$(mktemp -d)"

cleanup() {
  rm -rf "${TMPDIR_LOCAL}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

find_upstream_dir() {
  local pattern="$1"
  local match
  match="$(find "${SUBSTRATE_ROOT}" -maxdepth 1 -type d -name "${pattern}" | head -n 1 || true)"
  printf '%s' "${match}"
}

write_kustomization() {
  local resource="$1"
  local dir="${TMPDIR_LOCAL}/gateway-api-crds"
  local out="${dir}/kustomization.yaml"
  mkdir -p "${dir}"

  if [[ "${resource}" = /* ]]; then
    cp -R "${resource}" "${dir}/upstream-crd"
    resource="./upstream-crd"
  fi

  cat >"${out}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${resource}
EOF
  printf '%s' "${dir}"
}

apply_gateway_api_crds() {
  local kustomization="$1"
  echo "Applying Gateway API CRDs..."
  kubectl create namespace gateway-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -k "${kustomization}"
}

wait_for_gateway_api_crds() {
  local crds=(
    gatewayclasses.gateway.networking.k8s.io
    gateways.gateway.networking.k8s.io
    grpcroutes.gateway.networking.k8s.io
    httproutes.gateway.networking.k8s.io
    referencegrants.gateway.networking.k8s.io
    backendtlspolicies.gateway.networking.k8s.io
    listenersets.gateway.networking.k8s.io
    tlsroutes.gateway.networking.k8s.io
  )

  echo "Waiting for Gateway API CRDs to reach Established..."
  for crd in "${crds[@]}"; do
    kubectl wait --for=condition=Established "crd/${crd}" --timeout="${CRD_WAIT_TIMEOUT}"
  done
}

main() {
  require_cmd kubectl

  local gateway_resource="github.com/kubernetes-sigs/gateway-api/config/crd?ref=${GATEWAY_API_REF}"
  if [ "${USE_LOCAL_SUBSTRATE}" = "1" ] && [ -d "${SUBSTRATE_ROOT}" ]; then
    local gateway_dir
    gateway_dir="$(find_upstream_dir "kubernetes-sigs-gateway-api-*")"
    if [ -n "${gateway_dir}" ]; then
      gateway_resource="${gateway_dir}/config/crd"
      echo "Using local Gateway API substrate: ${gateway_resource}"
    fi
  fi

  local kustomization
  kustomization="$(write_kustomization "${gateway_resource}")"

  apply_gateway_api_crds "${kustomization}"
  wait_for_gateway_api_crds

  echo "Phase 00 Gateway API CRD verification passed."
}

main "$@"
