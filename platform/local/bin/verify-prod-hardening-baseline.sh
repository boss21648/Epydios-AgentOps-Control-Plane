#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
APPLY_NETWORK_POLICIES="${APPLY_NETWORK_POLICIES:-1}"
APPLY_MONITORING_RESOURCES="${APPLY_MONITORING_RESOURCES:-auto}" # auto|1|0
REQUIRE_MONITORING_CRDS="${REQUIRE_MONITORING_CRDS:-0}"
RUN_ROTATION_CHECK="${RUN_ROTATION_CHECK:-1}"
RUN_MONITORING_ALERT_SMOKE="${RUN_MONITORING_ALERT_SMOKE:-0}"
AUTO_INSTALL_MONITORING_STACK="${AUTO_INSTALL_MONITORING_STACK:-0}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME:-kube-prometheus-stack}"
MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS:-30}"
FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS:-0}"
RUN_ADMISSION_ENFORCEMENT_CHECK="${RUN_ADMISSION_ENFORCEMENT_CHECK:-1}"
APPLY_SIGNED_IMAGE_POLICY="${APPLY_SIGNED_IMAGE_POLICY:-auto}" # auto|1|0
REQUIRE_SIGNED_IMAGE_POLICY="${REQUIRE_SIGNED_IMAGE_POLICY:-0}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd kubectl
  if [ "${RUN_MONITORING_ALERT_SMOKE}" = "1" ]; then
    require_cmd curl
  fi

  if [ "${APPLY_NETWORK_POLICIES}" = "1" ]; then
    echo "Applying hardening NetworkPolicies..."
    kubectl apply -k "${REPO_ROOT}/platform/hardening/networkpolicy"
    kubectl -n "${NAMESPACE}" get networkpolicy
  fi

  local apply_monitoring="0"
  local monitoring_crds_present="0"
  if kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
    monitoring_crds_present="1"
  fi
  case "${APPLY_MONITORING_RESOURCES}" in
    1) apply_monitoring="1" ;;
    0) apply_monitoring="0" ;;
    auto)
      if [ "${monitoring_crds_present}" = "1" ]; then
        apply_monitoring="1"
      fi
      ;;
    *)
      echo "Unsupported APPLY_MONITORING_RESOURCES=${APPLY_MONITORING_RESOURCES} (expected auto|1|0)" >&2
      exit 1
      ;;
  esac

  if [ "${apply_monitoring}" = "1" ]; then
    echo "Applying monitoring hardening resources (ServiceMonitor + PrometheusRule)..."
    kubectl apply -k "${REPO_ROOT}/platform/hardening/monitoring"
    kubectl -n "${NAMESPACE}" get servicemonitor,prometheusrule
  elif [ "${REQUIRE_MONITORING_CRDS}" = "1" ]; then
    echo "Monitoring CRDs are required but not available." >&2
    echo "Install monitoring stack first or set AUTO_INSTALL_MONITORING_STACK=1 with RUN_MONITORING_ALERT_SMOKE=1." >&2
    exit 1
  else
    echo "Monitoring CRDs not present (or disabled); skipping ServiceMonitor/PrometheusRule apply."
  fi

  if [ "${RUN_ROTATION_CHECK}" = "1" ]; then
    echo "Running secret/cert rotation check..."
    NAMESPACE="${NAMESPACE}" \
    MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS}" \
    FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS}" \
      "${SCRIPT_DIR}/verify-secret-cert-rotation.sh"
  fi

  if [ "${RUN_ADMISSION_ENFORCEMENT_CHECK}" = "1" ]; then
    echo "Running admission enforcement check..."
    NAMESPACE="${NAMESPACE}" \
    APPLY_SIGNED_IMAGE_POLICY="${APPLY_SIGNED_IMAGE_POLICY}" \
    REQUIRE_SIGNED_IMAGE_POLICY="${REQUIRE_SIGNED_IMAGE_POLICY}" \
    CLEANUP_POLICIES=1 \
      "${SCRIPT_DIR}/verify-admission-enforcement.sh"
  fi

  if [ "${RUN_MONITORING_ALERT_SMOKE}" = "1" ]; then
    echo "Running monitoring alert smoke verification..."
    NAMESPACE="${NAMESPACE}" \
    MONITORING_NAMESPACE="${MONITORING_NAMESPACE}" \
    MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME}" \
    AUTO_INSTALL_MONITORING_STACK="${AUTO_INSTALL_MONITORING_STACK}" \
    APPLY_MONITORING_RESOURCES=0 \
    ALERT_SMOKE=1 \
      "${SCRIPT_DIR}/verify-monitoring-alerts.sh"
  fi

  echo "Production hardening baseline verification completed."
}

main "$@"
