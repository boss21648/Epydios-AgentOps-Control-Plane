#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK_PARENT="$(cd "${REPO_ROOT}/.." && pwd)"

ROLLOUTS_REF="${ROLLOUTS_REF:-dd8a4db3d5d053a90656490b648069bf63881133}"
EVENTS_REF="${EVENTS_REF:-f52ff16a737bca2fc10c794e00dd623017bc36bc}"
ROLLOUTS_IMAGE_TAG="${ROLLOUTS_IMAGE_TAG:-v1.8.4}"
EVENTS_IMAGE_TAG="${EVENTS_IMAGE_TAG:-v1.9.8}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-1}"
SUBSTRATE_ROOT="${SUBSTRATE_ROOT:-${WORK_PARENT}/SUBSTRATE_UPSTREAMS}"
CLEANUP_LEGACY_DEFAULT_ROLLOUTS="${CLEANUP_LEGACY_DEFAULT_ROLLOUTS:-1}"

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

write_rollouts_kustomization() {
  local resource="$1"
  local dir="${TMPDIR_LOCAL}/rollouts"
  local out="${dir}/kustomization.yaml"
  mkdir -p "${dir}"
  if [[ "${resource}" = /* ]]; then
    local manifests_root
    manifests_root="$(cd "${resource}/.." && pwd)"
    cp -R "${manifests_root}" "${dir}/upstream-manifests"
    resource="./upstream-manifests/cluster-install"
  fi
  cat >"${out}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argo-rollouts
resources:
  - ${resource}
images:
  - name: quay.io/argoproj/argo-rollouts
    newTag: ${ROLLOUTS_IMAGE_TAG}
EOF
  printf '%s' "${dir}"
}

write_events_kustomization() {
  local resource="$1"
  local dir="${TMPDIR_LOCAL}/events"
  local out="${dir}/kustomization.yaml"
  mkdir -p "${dir}"
  if [[ "${resource}" = /* ]]; then
    local manifests_root
    manifests_root="$(cd "${resource}/.." && pwd)"
    cp -R "${manifests_root}" "${dir}/upstream-manifests"
    resource="./upstream-manifests/cluster-install"
  fi
  cat >"${out}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${resource}
images:
  - name: quay.io/argoproj/argo-events
    newTag: ${EVENTS_IMAGE_TAG}
patches:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: controller-manager
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: controller-manager
      spec:
        template:
          spec:
            containers:
              - name: controller-manager
                env:
                  - name: ARGO_EVENTS_IMAGE
                    value: quay.io/argoproj/argo-events:${EVENTS_IMAGE_TAG}
                    valueFrom: null
EOF
  printf '%s' "${dir}"
}

apply_phase_component() {
  local component="$1"
  local kustomization="$2"
  echo "Applying ${component}..."
  kubectl apply -k "${kustomization}" 2> >(
    filter_kustomize_stderr
  )
}

filter_kustomize_stderr() {
  local line
  while IFS= read -r line; do
    case "${line}" in
      *"commonLabels' is deprecated"*)
        # Upstream Argo manifests still emit this deprecation warning.
        # Filter it to keep normal gate output warning-free.
        ;;
      *)
        echo "${line}" >&2
        ;;
    esac
  done
}

wait_for_phase_readiness() {
  echo "Waiting for Argo Rollouts controller..."
  kubectl -n argo-rollouts wait --for=condition=Available deployment/argo-rollouts --timeout=8m

  echo "Waiting for Argo Events controller..."
  kubectl -n argo-events wait --for=condition=Available deployment/controller-manager --timeout=8m

  echo "Validating CRDs..."
  kubectl get crd rollouts.argoproj.io >/dev/null
  kubectl get crd analysisruns.argoproj.io >/dev/null
  kubectl get crd analysistemplates.argoproj.io >/dev/null
  kubectl get crd clusteranalysistemplates.argoproj.io >/dev/null
  kubectl get crd experiments.argoproj.io >/dev/null
  kubectl get crd eventbus.argoproj.io >/dev/null
  kubectl get crd eventsources.argoproj.io >/dev/null
  kubectl get crd sensors.argoproj.io >/dev/null
}

handle_legacy_default_rollouts() {
  if ! kubectl -n default get deployment argo-rollouts >/dev/null 2>&1; then
    return 0
  fi
  if [ "${CLEANUP_LEGACY_DEFAULT_ROLLOUTS}" = "1" ]; then
    echo "Cleaning legacy default/argo-rollouts resources..."
    kubectl -n default delete deployment argo-rollouts --ignore-not-found
    kubectl -n default delete service argo-rollouts-metrics --ignore-not-found
    kubectl -n default delete configmap argo-rollouts-config --ignore-not-found
    kubectl -n default delete secret argo-rollouts-notification-secret --ignore-not-found
    kubectl -n default delete serviceaccount argo-rollouts --ignore-not-found
    return 0
  fi
  echo "Warning: legacy deployment default/argo-rollouts detected from older runs." >&2
  echo "Set CLEANUP_LEGACY_DEFAULT_ROLLOUTS=1 to remove stale default-namespace resources." >&2
}

main() {
  require_cmd kubectl

  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -
  handle_legacy_default_rollouts

  local rollouts_resource="github.com/argoproj/argo-rollouts/manifests/cluster-install?ref=${ROLLOUTS_REF}"
  local events_resource="github.com/argoproj/argo-events/manifests/cluster-install?ref=${EVENTS_REF}"

  if [ "${USE_LOCAL_SUBSTRATE}" = "1" ] && [ -d "${SUBSTRATE_ROOT}" ]; then
    local rollouts_dir events_dir
    rollouts_dir="$(find_upstream_dir "argoproj-argo-rollouts-*")"
    events_dir="$(find_upstream_dir "argoproj-argo-events-*")"
    if [ -n "${rollouts_dir}" ]; then
      rollouts_resource="${rollouts_dir}/manifests/cluster-install"
      echo "Using local Argo Rollouts substrate: ${rollouts_resource}"
    fi
    if [ -n "${events_dir}" ]; then
      events_resource="${events_dir}/manifests/cluster-install"
      echo "Using local Argo Events substrate: ${events_resource}"
    fi
  fi

  local rollouts_kustomization events_kustomization
  rollouts_kustomization="$(write_rollouts_kustomization "${rollouts_resource}")"
  events_kustomization="$(write_events_kustomization "${events_resource}")"

  apply_phase_component "Argo Rollouts" "${rollouts_kustomization}"
  apply_phase_component "Argo Events" "${events_kustomization}"
  wait_for_phase_readiness

  echo "Phase 02 delivery/events verification passed (Argo Rollouts + Argo Events)."
}

main "$@"
