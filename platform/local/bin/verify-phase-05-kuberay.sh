#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK_PARENT="$(cd "${REPO_ROOT}/.." && pwd)"

KUBERAY_NAMESPACE="${KUBERAY_NAMESPACE:-kuberay-system}"
KUBERAY_RELEASE="${KUBERAY_RELEASE:-kuberay-operator}"
KUBERAY_HELM_REPO_NAME="${KUBERAY_HELM_REPO_NAME:-kuberay}"
KUBERAY_HELM_REPO_URL="${KUBERAY_HELM_REPO_URL:-https://ray-project.github.io/kuberay-helm}"
KUBERAY_CHART="${KUBERAY_CHART:-kuberay-operator}"
KUBERAY_CHART_VERSION="${KUBERAY_CHART_VERSION:-1.1.0}"
KUBERAY_IMAGE_REPOSITORY="${KUBERAY_IMAGE_REPOSITORY:-quay.io/kuberay/operator}"
KUBERAY_IMAGE_TAG="${KUBERAY_IMAGE_TAG:-v1.1.0}"

RUN_PHASE_03="${RUN_PHASE_03:-0}"
RUN_FUNCTIONAL_SMOKE="${RUN_FUNCTIONAL_SMOKE:-1}"
SMOKE_NAMESPACE="${SMOKE_NAMESPACE:-kuberay-smoke}"

USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-0}"
SUBSTRATE_ROOT="${SUBSTRATE_ROOT:-${WORK_PARENT}/SUBSTRATE_UPSTREAMS}"

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

resolve_chart_ref() {
  if [ "${USE_LOCAL_SUBSTRATE}" = "1" ] && [ -d "${SUBSTRATE_ROOT}" ]; then
    local kuberay_dir local_chart
    kuberay_dir="$(find_upstream_dir "ray-project-kuberay-*")"
    local_chart="${kuberay_dir}/helm-chart/${KUBERAY_CHART}"
    if [ -n "${kuberay_dir}" ] && [ -d "${local_chart}" ]; then
      echo "Using local KubeRay substrate chart: ${local_chart}" >&2
      printf '%s' "${local_chart}"
      return 0
    fi
  fi

  helm repo add "${KUBERAY_HELM_REPO_NAME}" "${KUBERAY_HELM_REPO_URL}" >/dev/null 2>&1 || true
  helm repo update >/dev/null
  printf '%s/%s' "${KUBERAY_HELM_REPO_NAME}" "${KUBERAY_CHART}"
}

install_kuberay() {
  local chart_ref="$1"
  local helm_args
  helm_args=(
    upgrade
    --install
    "${KUBERAY_RELEASE}"
    "${chart_ref}"
    --namespace "${KUBERAY_NAMESPACE}"
    --create-namespace
    --set "image.repository=${KUBERAY_IMAGE_REPOSITORY}"
    --set "image.tag=${KUBERAY_IMAGE_TAG}"
  )
  if [[ "${chart_ref}" != /* ]]; then
    helm_args+=(--version "${KUBERAY_CHART_VERSION}")
  fi
  helm "${helm_args[@]}"
}

resolve_operator_deployment() {
  if kubectl -n "${KUBERAY_NAMESPACE}" get deployment "${KUBERAY_RELEASE}" >/dev/null 2>&1; then
    printf '%s' "${KUBERAY_RELEASE}"
    return 0
  fi

  local deployment_name
  deployment_name="$(
    kubectl -n "${KUBERAY_NAMESPACE}" get deployment \
      -l app.kubernetes.io/name=kuberay-operator \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  if [ -z "${deployment_name}" ]; then
    echo "Unable to find KubeRay operator deployment in namespace ${KUBERAY_NAMESPACE}." >&2
    kubectl -n "${KUBERAY_NAMESPACE}" get deployment -o wide >&2 || true
    return 1
  fi

  printf '%s' "${deployment_name}"
}

wait_for_kuberay() {
  local deployment_name
  deployment_name="$(resolve_operator_deployment)"
  kubectl -n "${KUBERAY_NAMESPACE}" wait --for=condition=Available "deployment/${deployment_name}" --timeout=10m
}

verify_kuberay_crds() {
  kubectl get crd rayclusters.ray.io >/dev/null
  kubectl get crd rayjobs.ray.io >/dev/null
  kubectl get crd rayservices.ray.io >/dev/null
  kubectl get crd raycronjobs.ray.io >/dev/null
}

main() {
  require_cmd kubectl
  require_cmd helm

  if [ "${RUN_PHASE_03}" = "1" ]; then
    echo "Running Phase 03 verification first..."
    RUN_PHASE_02="${RUN_PHASE_02:-0}" \
    RUN_FUNCTIONAL_SMOKE="${RUN_PHASE_03_FUNCTIONAL_SMOKE:-1}" \
    USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
    AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-1}" \
    FORCE_CONFLICTS="${FORCE_CONFLICTS:-1}" \
      "${SCRIPT_DIR}/verify-phase-03-kserve.sh"
  fi

  local chart_ref
  chart_ref="$(resolve_chart_ref)"

  install_kuberay "${chart_ref}"
  wait_for_kuberay
  verify_kuberay_crds

  if [ "${RUN_FUNCTIONAL_SMOKE}" = "1" ]; then
    NAMESPACE="${SMOKE_NAMESPACE}" "${SCRIPT_DIR}/smoke-kuberay-raycluster.sh"
  fi

  echo "Phase 05 KubeRay verification passed."
}

main "$@"
