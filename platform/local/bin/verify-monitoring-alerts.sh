#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME:-kube-prometheus-stack}"
AUTO_INSTALL_MONITORING_STACK="${AUTO_INSTALL_MONITORING_STACK:-0}"
APPLY_MONITORING_RESOURCES="${APPLY_MONITORING_RESOURCES:-1}"
ALERT_SMOKE="${ALERT_SMOKE:-1}"
ALERT_SMOKE_FOR_SECONDS="${ALERT_SMOKE_FOR_SECONDS:-75}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-360}"
PROM_PORT="${PROM_PORT:-19090}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-19093}"

TMPDIR_LOCAL="$(mktemp -d)"
PROM_PF_PID=""
ALERTMANAGER_PF_PID=""
SMOKE_RULE_APPLIED=0

cleanup() {
  if [ "${SMOKE_RULE_APPLIED}" = "1" ]; then
    kubectl -n "${NAMESPACE}" delete -f "${TMPDIR_LOCAL}/prometheusrule-alert-smoke.yaml" --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [ -n "${PROM_PF_PID}" ] && kill -0 "${PROM_PF_PID}" >/dev/null 2>&1; then
    kill "${PROM_PF_PID}" >/dev/null 2>&1 || true
    wait "${PROM_PF_PID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${ALERTMANAGER_PF_PID}" ] && kill -0 "${ALERTMANAGER_PF_PID}" >/dev/null 2>&1; then
    kill "${ALERTMANAGER_PF_PID}" >/dev/null 2>&1 || true
    wait "${ALERTMANAGER_PF_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPDIR_LOCAL}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

wait_for_http_ok() {
  local url="$1"
  local start
  start="$(date +%s)"
  while true; do
    if curl --connect-timeout 2 --max-time 5 -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for HTTP readiness: ${url}" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_pattern() {
  local url="$1"
  local pattern="$2"
  local start body
  start="$(date +%s)"
  while true; do
    body="$(curl --connect-timeout 2 --max-time 5 -fsS "${url}" 2>/dev/null || true)"
    if printf '%s' "${body}" | grep -q "${pattern}"; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for pattern '${pattern}' at ${url}" >&2
      return 1
    fi
    sleep 3
  done
}

discover_prometheus_pod() {
  local pod
  pod="$(kubectl -n "${MONITORING_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=${MONITORING_RELEASE_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    printf '%s' "${pod}"
    return 0
  fi
  kubectl -n "${MONITORING_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

discover_alertmanager_pod() {
  local pod
  pod="$(kubectl -n "${MONITORING_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=alertmanager,app.kubernetes.io/instance=${MONITORING_RELEASE_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    printf '%s' "${pod}"
    return 0
  fi
  kubectl -n "${MONITORING_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=alertmanager" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

start_port_forwards() {
  local prom_pod alertmanager_pod

  prom_pod="$(discover_prometheus_pod)"
  if [ -z "${prom_pod}" ]; then
    echo "Unable to discover Prometheus pod in namespace ${MONITORING_NAMESPACE}" >&2
    kubectl -n "${MONITORING_NAMESPACE}" get pods >&2 || true
    exit 1
  fi
  kubectl -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready "pod/${prom_pod}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
  kubectl -n "${MONITORING_NAMESPACE}" port-forward "pod/${prom_pod}" "${PROM_PORT}:9090" >"${TMPDIR_LOCAL}/pf-prom.log" 2>&1 &
  PROM_PF_PID="$!"
  wait_for_http_ok "http://127.0.0.1:${PROM_PORT}/-/ready"

  alertmanager_pod="$(discover_alertmanager_pod)"
  if [ -z "${alertmanager_pod}" ]; then
    echo "Unable to discover Alertmanager pod in namespace ${MONITORING_NAMESPACE}" >&2
    kubectl -n "${MONITORING_NAMESPACE}" get pods >&2 || true
    exit 1
  fi
  kubectl -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready "pod/${alertmanager_pod}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
  kubectl -n "${MONITORING_NAMESPACE}" port-forward "pod/${alertmanager_pod}" "${ALERTMANAGER_PORT}:9093" >"${TMPDIR_LOCAL}/pf-alertmanager.log" 2>&1 &
  ALERTMANAGER_PF_PID="$!"
  wait_for_http_ok "http://127.0.0.1:${ALERTMANAGER_PORT}/-/ready"
}

assert_rule_loaded() {
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosExtensionProviderRegistryControllerUnavailable"
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosControlPlaneProviderCrashLooping"
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosRuntimeAvailabilitySLOBurnFast"
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosRuntimeLatencySLIHigh"
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosRuntimeRunSuccessSLILow"
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/rules" \
    "EpydiosRuntimeProviderErrorRateHigh"
}

apply_alert_smoke_rule() {
  cat >"${TMPDIR_LOCAL}/prometheusrule-alert-smoke.yaml" <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: epydios-monitoring-alert-smoke
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: extension-provider-registry-controller
    app.kubernetes.io/component: hardening
    app.kubernetes.io/part-of: epydios-ai-control-plane
spec:
  groups:
    - name: epydios.monitoring.smoke.rules
      rules:
        - alert: EpydiosMonitoringAlertSmokeAlwaysOn
          expr: vector(1)
          for: ${ALERT_SMOKE_FOR_SECONDS}s
          labels:
            severity: warning
          annotations:
            summary: "Epydios monitoring alert smoke"
            description: "Synthetic always-on alert used to validate alert pipeline."
EOF

  kubectl apply -f "${TMPDIR_LOCAL}/prometheusrule-alert-smoke.yaml" >/dev/null
  SMOKE_RULE_APPLIED=1
}

assert_alert_pipeline() {
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/alerts" \
    'EpydiosMonitoringAlertSmokeAlwaysOn'
  wait_for_pattern \
    "http://127.0.0.1:${PROM_PORT}/api/v1/alerts" \
    '"state":"firing"'

  wait_for_pattern \
    "http://127.0.0.1:${ALERTMANAGER_PORT}/api/v2/alerts" \
    'EpydiosMonitoringAlertSmokeAlwaysOn'
}

main() {
  require_cmd kubectl
  require_cmd curl
  require_cmd rg

  if [ "${AUTO_INSTALL_MONITORING_STACK}" = "1" ]; then
    MONITORING_NAMESPACE="${MONITORING_NAMESPACE}" \
    MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME}" \
      "${SCRIPT_DIR}/bootstrap-monitoring-stack.sh"
  fi

  if [ "${APPLY_MONITORING_RESOURCES}" = "1" ]; then
    echo "Applying monitoring hardening resources..."
    kubectl apply -k "${REPO_ROOT}/platform/hardening/monitoring"
  fi

  echo "Checking monitoring CRDs..."
  kubectl get crd \
    servicemonitors.monitoring.coreos.com \
    prometheusrules.monitoring.coreos.com \
    prometheuses.monitoring.coreos.com \
    alertmanagers.monitoring.coreos.com >/dev/null

  echo "Checking monitoring resources in namespace ${NAMESPACE}..."
  kubectl -n "${NAMESPACE}" get servicemonitor epydios-extension-provider-registry-controller >/dev/null
  kubectl -n "${NAMESPACE}" get servicemonitor orchestration-runtime >/dev/null
  kubectl -n "${NAMESPACE}" get prometheusrule epydios-extension-provider-registry-controller >/dev/null
  kubectl -n "${NAMESPACE}" get prometheusrule epydios-runtime-slo >/dev/null

  echo "Starting Prometheus/Alertmanager API checks..."
  start_port_forwards
  assert_rule_loaded

  if [ "${ALERT_SMOKE}" = "1" ]; then
    echo "Running alert firing smoke..."
    apply_alert_smoke_rule
    assert_alert_pipeline
  fi

  echo "Monitoring alert verification passed."
  echo "  monitoring_namespace=${MONITORING_NAMESPACE}"
  echo "  monitoring_release=${MONITORING_RELEASE_NAME}"
  echo "  monitored_namespace=${NAMESPACE}"
  if [ "${ALERT_SMOKE}" = "1" ]; then
    echo "  alert_smoke=enabled"
  else
    echo "  alert_smoke=disabled"
  fi
}

main "$@"
