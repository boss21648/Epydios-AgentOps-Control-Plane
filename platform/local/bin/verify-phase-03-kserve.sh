#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK_PARENT="$(cd "${REPO_ROOT}/.." && pwd)"

KSERVE_REF="${KSERVE_REF:-af8ce37d57f8ef13430cbdad5851ad0bdbe5dff3}"
KSERVE_IMAGE_TAG="${KSERVE_IMAGE_TAG:-v0.16.0}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-1}"
SUBSTRATE_ROOT="${SUBSTRATE_ROOT:-${WORK_PARENT}/SUBSTRATE_UPSTREAMS}"

RUN_PHASE_02="${RUN_PHASE_02:-0}"
AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-1}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.19.4}"
FORCE_CONFLICTS="${FORCE_CONFLICTS:-1}"
RUN_FUNCTIONAL_SMOKE="${RUN_FUNCTIONAL_SMOKE:-1}"

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
  local dir="${TMPDIR_LOCAL}/kserve"
  local out="${dir}/kustomization.yaml"
  mkdir -p "${dir}"

  if [[ "${resource}" = /* ]]; then
    local overlays_root
    overlays_root="$(cd "${resource}/../../.." && pwd)"
    cp -R "${overlays_root}" "${dir}/config"
    resource="./config/overlays/standalone/kserve"
  fi

  cat >"${out}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${resource}
images:
  - name: kserve/kserve-controller
    newTag: ${KSERVE_IMAGE_TAG}
EOF
  printf '%s' "${dir}"
}

apply_kserve() {
  local kustomization="$1"
  echo "Applying KServe (standalone overlay)..."
  local apply_args=(--server-side)
  if [ "${FORCE_CONFLICTS}" = "1" ]; then
    apply_args+=(--force-conflicts)
    echo "Using server-side apply with force-conflicts (migration-safe for pre-existing client-side fields)."
  fi
  kubectl apply "${apply_args[@]}" -k "${kustomization}"
}

wait_for_kserve() {
  echo "Waiting for KServe controller..."
  kubectl -n kserve wait --for=condition=Available deployment/kserve-controller-manager --timeout=10m
}

verify_kserve_crds() {
  echo "Validating KServe CRDs..."
  kubectl get crd inferenceservices.serving.kserve.io >/dev/null
  kubectl get crd trainedmodels.serving.kserve.io >/dev/null
  kubectl get crd clusterservingruntimes.serving.kserve.io >/dev/null
  kubectl get crd servingruntimes.serving.kserve.io >/dev/null
  kubectl get crd inferencegraphs.serving.kserve.io >/dev/null
  kubectl get crd clusterstoragecontainers.serving.kserve.io >/dev/null
}

ensure_cert_manager() {
  if kubectl get crd certificates.cert-manager.io issuers.cert-manager.io >/dev/null 2>&1; then
    return 0
  fi

  if [ "${AUTO_INSTALL_CERT_MANAGER}" != "1" ]; then
    echo "Missing cert-manager CRDs (certificates.cert-manager.io, issuers.cert-manager.io)." >&2
    echo "Install cert-manager first or set AUTO_INSTALL_CERT_MANAGER=1." >&2
    exit 1
  fi

  require_cmd helm

  echo "Installing cert-manager ${CERT_MANAGER_CHART_VERSION} (required by KServe webhooks)..."
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_CHART_VERSION}" \
    --set crds.enabled=true

  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager --timeout=8m
  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout=8m
  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-cainjector --timeout=8m

  kubectl get crd certificates.cert-manager.io issuers.cert-manager.io >/dev/null
}

main() {
  require_cmd kubectl

  if [ "${RUN_PHASE_02}" = "1" ]; then
    "${SCRIPT_DIR}/verify-phase-02-delivery-events.sh"
  fi

  ensure_cert_manager

  kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -

  local kserve_resource="github.com/kserve/kserve/config/overlays/standalone/kserve?ref=${KSERVE_REF}"
  if [ "${USE_LOCAL_SUBSTRATE}" = "1" ] && [ -d "${SUBSTRATE_ROOT}" ]; then
    local kserve_dir
    kserve_dir="$(find_upstream_dir "kserve-kserve-*")"
    if [ -n "${kserve_dir}" ]; then
      kserve_resource="${kserve_dir}/config/overlays/standalone/kserve"
      echo "Using local KServe substrate: ${kserve_resource}"
    fi
  fi

  local kustomization
  kustomization="$(write_kustomization "${kserve_resource}")"

  apply_kserve "${kustomization}"
  wait_for_kserve
  verify_kserve_crds
  if [ "${RUN_FUNCTIONAL_SMOKE}" = "1" ]; then
    "${SCRIPT_DIR}/smoke-kserve-inferenceservice.sh"
  fi

  echo "Phase 03 KServe verification passed."
}

main "$@"
