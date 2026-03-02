#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
RUN_CLUSTER_ASSERTIONS="${RUN_CLUSTER_ASSERTIONS:-auto}" # auto|1|0

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

assert_file() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    echo "Missing required file: ${path}" >&2
    exit 1
  fi
}

assert_pattern() {
  local path="$1"
  local pattern="$2"
  if ! rg -q "${pattern}" "${path}"; then
    echo "Missing expected pattern in ${path}: ${pattern}" >&2
    exit 1
  fi
}

crds_present() {
  kubectl get crd \
    servicemonitors.monitoring.coreos.com \
    prometheusrules.monitoring.coreos.com >/dev/null 2>&1
}

main() {
  require_cmd rg
  require_cmd kubectl

  local runbook monitor_kustom runtime_rule runtime_monitor
  runbook="${REPO_ROOT}/docs/runbooks/slo-sli-error-budget.md"
  monitor_kustom="${REPO_ROOT}/platform/hardening/monitoring/kustomization.yaml"
  runtime_rule="${REPO_ROOT}/platform/hardening/monitoring/prometheusrule-runtime-slo.yaml"
  runtime_monitor="${REPO_ROOT}/platform/hardening/monitoring/servicemonitor-orchestration-runtime.yaml"

  assert_file "${runbook}"
  assert_file "${monitor_kustom}"
  assert_file "${runtime_rule}"
  assert_file "${runtime_monitor}"

  assert_pattern "${runbook}" "## SLI Definitions"
  assert_pattern "${runbook}" "## SLO Targets"
  assert_pattern "${runbook}" "## Error Budget Policy"
  assert_pattern "${runbook}" "## Alert Mapping"
  assert_pattern "${runbook}" "verify-m12-slo-sli-pack.sh"

  assert_pattern "${monitor_kustom}" "servicemonitor-orchestration-runtime.yaml"
  assert_pattern "${monitor_kustom}" "prometheusrule-runtime-slo.yaml"

  assert_pattern "${runtime_rule}" "alert: EpydiosRuntimeAvailabilitySLOBurnFast"
  assert_pattern "${runtime_rule}" "alert: EpydiosRuntimeAvailabilitySLOBurnSlow"
  assert_pattern "${runtime_rule}" "alert: EpydiosRuntimeLatencySLIHigh"
  assert_pattern "${runtime_rule}" "alert: EpydiosRuntimeRunSuccessSLILow"
  assert_pattern "${runtime_rule}" "alert: EpydiosRuntimeProviderErrorRateHigh"

  case "${RUN_CLUSTER_ASSERTIONS}" in
    1)
      ;;
    0)
      echo "Skipping cluster assertions (RUN_CLUSTER_ASSERTIONS=0)."
      echo "M12.1 SLO/SLI pack verification passed (file assertions only)."
      return 0
      ;;
    auto)
      if ! crds_present; then
        echo "Skipping cluster assertions (monitoring CRDs not present)."
        echo "M12.1 SLO/SLI pack verification passed (file assertions only)."
        return 0
      fi
      ;;
    *)
      echo "Unsupported RUN_CLUSTER_ASSERTIONS=${RUN_CLUSTER_ASSERTIONS} (expected auto|1|0)." >&2
      exit 1
      ;;
  esac

  if ! crds_present; then
    echo "RUN_CLUSTER_ASSERTIONS=${RUN_CLUSTER_ASSERTIONS} requires monitoring CRDs." >&2
    exit 1
  fi

  kubectl -n "${NAMESPACE}" get servicemonitor epydios-extension-provider-registry-controller >/dev/null
  kubectl -n "${NAMESPACE}" get servicemonitor orchestration-runtime >/dev/null
  kubectl -n "${NAMESPACE}" get prometheusrule epydios-extension-provider-registry-controller >/dev/null
  kubectl -n "${NAMESPACE}" get prometheusrule epydios-runtime-slo >/dev/null

  echo "M12.1 SLO/SLI pack verification passed."
}

main "$@"
