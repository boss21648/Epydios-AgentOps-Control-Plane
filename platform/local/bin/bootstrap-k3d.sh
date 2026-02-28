#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
WITH_SYSTEM_SMOKETEST="${WITH_SYSTEM_SMOKETEST:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
K3D_CONFIG="${REPO_ROOT}/platform/local/k3d/cluster.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

wait_for_default_storageclass() {
  local timeout_seconds=60
  local start
  start="$(date +%s)"
  while true; do
    if kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -q "true"; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${timeout_seconds}" ]; then
      echo "No default StorageClass detected after ${timeout_seconds}s. CNPG PVCs will not bind." >&2
      return 1
    fi
    sleep 2
  done
}

install_cnpg_operator() {
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
  helm repo update >/dev/null
  helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
    --namespace cnpg-system \
    --create-namespace \
    --version 0.27.1

  kubectl -n cnpg-system wait \
    --for=condition=Available \
    deployment \
    -l app.kubernetes.io/name=cloudnative-pg \
    --timeout=5m
}

apply_repo_manifests_and_smoketest() {
  kubectl apply -k "${REPO_ROOT}/platform/base"
  kubectl apply -k "${REPO_ROOT}/platform/data/cnpg-test-cluster"

  kubectl -n epydios-system wait \
    --for=condition=Ready \
    cluster.postgresql.cnpg.io/epydios-postgres \
    --timeout=10m

  kubectl -n epydios-system delete job epydios-postgres-smoketest --ignore-not-found
  kubectl apply -k "${REPO_ROOT}/platform/data/postgres-smoketest"

  kubectl -n epydios-system wait \
    --for=condition=complete \
    job/epydios-postgres-smoketest \
    --timeout=10m

  kubectl -n epydios-system logs job/epydios-postgres-smoketest
}

maybe_run_system_smoketest() {
  if [ "${WITH_SYSTEM_SMOKETEST}" != "1" ]; then
    return 0
  fi

  "${SCRIPT_DIR}/build-local-images.sh"
  CLUSTER_NAME="${CLUSTER_NAME}" "${SCRIPT_DIR}/load-local-images-k3d.sh"
  "${SCRIPT_DIR}/smoke-provider-discovery.sh"
}

main() {
  require_cmd k3d
  require_cmd kubectl
  require_cmd helm
  require_cmd docker

  if [ "${CLUSTER_NAME}" != "epydios-dev" ]; then
    echo "bootstrap-k3d.sh currently expects CLUSTER_NAME=epydios-dev (matches platform/local/k3d/cluster.yaml)." >&2
    exit 1
  fi

  if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
    echo "k3d cluster '${CLUSTER_NAME}' already exists; reusing it."
  else
    k3d cluster create --config "${K3D_CONFIG}"
  fi

  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
  wait_for_default_storageclass
  install_cnpg_operator
  apply_repo_manifests_and_smoketest
  maybe_run_system_smoketest

  echo
  echo "Local CNPG/Postgres smoke path complete on k3d cluster '${CLUSTER_NAME}'."
}

main "$@"
