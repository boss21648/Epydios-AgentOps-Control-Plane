#!/usr/bin/env bash
set -euo pipefail

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME:-kube-prometheus-stack}"
CHART_REPO_NAME="${CHART_REPO_NAME:-prometheus-community}"
CHART_REPO_URL="${CHART_REPO_URL:-https://prometheus-community.github.io/helm-charts}"
CHART_NAME="${CHART_NAME:-kube-prometheus-stack}"
CHART_VERSION="${CHART_VERSION:-}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd helm
  require_cmd kubectl

  echo "Ensuring monitoring namespace exists (${MONITORING_NAMESPACE})..."
  kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${MONITORING_NAMESPACE}"

  echo "Adding/updating Helm repo ${CHART_REPO_NAME} (${CHART_REPO_URL})..."
  helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}" >/dev/null 2>&1 || true
  helm repo update "${CHART_REPO_NAME}" >/dev/null

  local chart_ref
  local -a helm_cmd
  chart_ref="${CHART_REPO_NAME}/${CHART_NAME}"

  echo "Installing/upgrading ${chart_ref} (${MONITORING_RELEASE_NAME})..."
  helm_cmd=(
    helm upgrade --install "${MONITORING_RELEASE_NAME}" "${chart_ref}"
    --namespace "${MONITORING_NAMESPACE}"
    --create-namespace
  )
  if [ -n "${CHART_VERSION}" ]; then
    helm_cmd+=(--version "${CHART_VERSION}")
  fi
  helm_cmd+=(
    --wait
    --timeout "${HELM_TIMEOUT}"
    --set grafana.enabled=false
    --set kubeControllerManager.enabled=false
    --set kubeEtcd.enabled=false
    --set kubeProxy.enabled=false
    --set kubeScheduler.enabled=false
    --set prometheus.prometheusSpec.retention=24h
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
    --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
    --set prometheus.prometheusSpec.probeSelectorNilUsesHelmValues=false
  )
  "${helm_cmd[@]}"

  echo "Validating monitoring CRDs..."
  kubectl get crd \
    servicemonitors.monitoring.coreos.com \
    prometheusrules.monitoring.coreos.com \
    prometheuses.monitoring.coreos.com \
    alertmanagers.monitoring.coreos.com >/dev/null

  echo "Monitoring stack bootstrap complete."
  echo "  namespace=${MONITORING_NAMESPACE}"
  echo "  release=${MONITORING_RELEASE_NAME}"
  if [ -n "${CHART_VERSION}" ]; then
    echo "  chart_version=${CHART_VERSION}"
  else
    echo "  chart_version=<repo default>"
  fi
}

main "$@"
