#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
KIND_CONFIG="${KIND_CONFIG:-${REPO_ROOT}/platform/local/kind/cluster.yaml}"

GATE_MODE="${GATE_MODE:-full}" # full | fast

RUN_PHASE_02="${RUN_PHASE_02:-}"
RUN_PHASE_00_01="${RUN_PHASE_00_01:-}"
RUN_GATEWAY_API="${RUN_GATEWAY_API:-}"
RUN_FUNCTIONAL_SMOKE="${RUN_FUNCTIONAL_SMOKE:-}"
RUN_PHASE_04="${RUN_PHASE_04:-}"
RUN_PHASE_04_SECURE="${RUN_PHASE_04_SECURE:-}"
RUN_PHASE_RUNTIME="${RUN_PHASE_RUNTIME:-}"
RUN_PHASE_RUNTIME_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP:-}"
RUN_PHASE_RUNTIME_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP:-}"
RUN_M9_AUTHN_AUTHZ="${RUN_M9_AUTHN_AUTHZ:-}"
RUN_M9_AUTHZ_TENANCY="${RUN_M9_AUTHZ_TENANCY:-}"
RUN_M9_RBAC_MATRIX="${RUN_M9_RBAC_MATRIX:-}"
RUN_M9_AUDIT_READ="${RUN_M9_AUDIT_READ:-}"
RUN_M10_PROVIDER_CONFORMANCE="${RUN_M10_PROVIDER_CONFORMANCE:-}"
RUN_M10_POLICY_GRANT_ENFORCEMENT="${RUN_M10_POLICY_GRANT_ENFORCEMENT:-}"
RUN_M10_AIMXS_PRIVATE_RELEASE="${RUN_M10_AIMXS_PRIVATE_RELEASE:-}"
RUN_M7_INTEGRATION="${RUN_M7_INTEGRATION:-}"
RUN_M7_BACKUP_RESTORE="${RUN_M7_BACKUP_RESTORE:-}"
RUN_M7_UPGRADE_SAFETY="${RUN_M7_UPGRADE_SAFETY:-}"
RUN_PRODUCTION_PLACEHOLDER_CHECK="${RUN_PRODUCTION_PLACEHOLDER_CHECK:-}"
RUN_PHASE_05="${RUN_PHASE_05:-}"
RUN_PHASE_05_FUNCTIONAL_SMOKE="${RUN_PHASE_05_FUNCTIONAL_SMOKE:-}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-}"
AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-}"
FORCE_CONFLICTS="${FORCE_CONFLICTS:-}"
RUN_PROVENANCE_CHECK="${RUN_PROVENANCE_CHECK:-}"
PROVENANCE_STRICT="${PROVENANCE_STRICT:-}"
RUN_ROTATION_CHECK="${RUN_ROTATION_CHECK:-}"
MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS:-}"
FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS:-}"
RUN_HARDENING_BASELINE="${RUN_HARDENING_BASELINE:-}"
APPLY_NETWORK_POLICIES="${APPLY_NETWORK_POLICIES:-}"
APPLY_MONITORING_RESOURCES="${APPLY_MONITORING_RESOURCES:-}"
REQUIRE_MONITORING_CRDS="${REQUIRE_MONITORING_CRDS:-}"
RUN_MONITORING_ALERT_SMOKE="${RUN_MONITORING_ALERT_SMOKE:-}"
AUTO_INSTALL_MONITORING_STACK="${AUTO_INSTALL_MONITORING_STACK:-}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-}"
MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME:-}"
RUN_ADMISSION_ENFORCEMENT_CHECK="${RUN_ADMISSION_ENFORCEMENT_CHECK:-}"
APPLY_SIGNED_IMAGE_POLICY="${APPLY_SIGNED_IMAGE_POLICY:-}"
REQUIRE_SIGNED_IMAGE_POLICY="${REQUIRE_SIGNED_IMAGE_POLICY:-}"
RUN_AIMXS_BOUNDARY_CHECK="${RUN_AIMXS_BOUNDARY_CHECK:-}"

phase04_cleanup_secure_fixtures="1"
secure_fixture_cleanup_done="0"

set_default_if_unset() {
  local var_name="$1"
  local default_value="$2"
  if [ -z "${!var_name:-}" ]; then
    printf -v "${var_name}" '%s' "${default_value}"
  fi
}

apply_gate_mode_defaults() {
  case "${GATE_MODE}" in
    full)
      set_default_if_unset RUN_PHASE_02 1
      set_default_if_unset RUN_PHASE_00_01 1
      set_default_if_unset RUN_GATEWAY_API 1
      set_default_if_unset RUN_FUNCTIONAL_SMOKE 1
      set_default_if_unset RUN_PHASE_04 1
      set_default_if_unset RUN_PHASE_04_SECURE 1
      set_default_if_unset RUN_PHASE_RUNTIME 1
      set_default_if_unset RUN_PHASE_RUNTIME_BOOTSTRAP 1
      set_default_if_unset RUN_PHASE_RUNTIME_IMAGE_PREP 1
      set_default_if_unset RUN_M9_AUTHN_AUTHZ 1
      set_default_if_unset RUN_M9_AUTHZ_TENANCY 1
      set_default_if_unset RUN_M9_RBAC_MATRIX 1
      set_default_if_unset RUN_M9_AUDIT_READ 1
      set_default_if_unset RUN_M10_PROVIDER_CONFORMANCE 1
      set_default_if_unset RUN_M10_POLICY_GRANT_ENFORCEMENT 1
      set_default_if_unset RUN_M10_AIMXS_PRIVATE_RELEASE 1
      set_default_if_unset RUN_M7_INTEGRATION 1
      set_default_if_unset RUN_M7_BACKUP_RESTORE 1
      set_default_if_unset RUN_M7_UPGRADE_SAFETY 1
      set_default_if_unset RUN_PRODUCTION_PLACEHOLDER_CHECK 1
      set_default_if_unset RUN_PHASE_05 0
      set_default_if_unset RUN_PHASE_05_FUNCTIONAL_SMOKE 1
      set_default_if_unset USE_LOCAL_SUBSTRATE 0
      set_default_if_unset AUTO_INSTALL_CERT_MANAGER 1
      set_default_if_unset FORCE_CONFLICTS 1
      set_default_if_unset RUN_PROVENANCE_CHECK 1
      set_default_if_unset PROVENANCE_STRICT 1
      set_default_if_unset RUN_ROTATION_CHECK 1
      set_default_if_unset MIN_TLS_VALIDITY_DAYS 30
      set_default_if_unset FAIL_ON_NO_MTLS_REFS 1
      set_default_if_unset RUN_HARDENING_BASELINE 1
      set_default_if_unset APPLY_NETWORK_POLICIES 1
      set_default_if_unset APPLY_MONITORING_RESOURCES auto
      set_default_if_unset REQUIRE_MONITORING_CRDS 0
      set_default_if_unset RUN_MONITORING_ALERT_SMOKE 0
      set_default_if_unset AUTO_INSTALL_MONITORING_STACK 0
      set_default_if_unset MONITORING_NAMESPACE monitoring
      set_default_if_unset MONITORING_RELEASE_NAME kube-prometheus-stack
      set_default_if_unset RUN_ADMISSION_ENFORCEMENT_CHECK 1
      set_default_if_unset APPLY_SIGNED_IMAGE_POLICY 1
      set_default_if_unset REQUIRE_SIGNED_IMAGE_POLICY 1
      set_default_if_unset RUN_AIMXS_BOUNDARY_CHECK 1
      ;;
    fast)
      # Fast mode favors iteration speed. Any explicitly provided env vars still override these defaults.
      set_default_if_unset RUN_PHASE_02 0
      set_default_if_unset RUN_PHASE_00_01 0
      set_default_if_unset RUN_GATEWAY_API 0
      set_default_if_unset RUN_FUNCTIONAL_SMOKE 0
      set_default_if_unset RUN_PHASE_04 0
      set_default_if_unset RUN_PHASE_04_SECURE 0
      set_default_if_unset RUN_PHASE_RUNTIME 0
      set_default_if_unset RUN_PHASE_RUNTIME_BOOTSTRAP 0
      set_default_if_unset RUN_PHASE_RUNTIME_IMAGE_PREP 0
      set_default_if_unset RUN_M9_AUTHN_AUTHZ 0
      set_default_if_unset RUN_M9_AUTHZ_TENANCY 0
      set_default_if_unset RUN_M9_RBAC_MATRIX 0
      set_default_if_unset RUN_M9_AUDIT_READ 0
      set_default_if_unset RUN_M10_PROVIDER_CONFORMANCE 0
      set_default_if_unset RUN_M10_POLICY_GRANT_ENFORCEMENT 0
      set_default_if_unset RUN_M10_AIMXS_PRIVATE_RELEASE 0
      set_default_if_unset RUN_M7_INTEGRATION 0
      set_default_if_unset RUN_M7_BACKUP_RESTORE 0
      set_default_if_unset RUN_M7_UPGRADE_SAFETY 0
      set_default_if_unset RUN_PRODUCTION_PLACEHOLDER_CHECK 0
      set_default_if_unset RUN_PHASE_05 0
      set_default_if_unset RUN_PHASE_05_FUNCTIONAL_SMOKE 0
      set_default_if_unset USE_LOCAL_SUBSTRATE 0
      set_default_if_unset AUTO_INSTALL_CERT_MANAGER 1
      set_default_if_unset FORCE_CONFLICTS 1
      set_default_if_unset RUN_PROVENANCE_CHECK 0
      set_default_if_unset PROVENANCE_STRICT 1
      set_default_if_unset RUN_ROTATION_CHECK 0
      set_default_if_unset MIN_TLS_VALIDITY_DAYS 30
      set_default_if_unset FAIL_ON_NO_MTLS_REFS 0
      set_default_if_unset RUN_HARDENING_BASELINE 0
      set_default_if_unset APPLY_NETWORK_POLICIES 1
      set_default_if_unset APPLY_MONITORING_RESOURCES auto
      set_default_if_unset REQUIRE_MONITORING_CRDS 0
      set_default_if_unset RUN_MONITORING_ALERT_SMOKE 0
      set_default_if_unset AUTO_INSTALL_MONITORING_STACK 0
      set_default_if_unset MONITORING_NAMESPACE monitoring
      set_default_if_unset MONITORING_RELEASE_NAME kube-prometheus-stack
      set_default_if_unset RUN_ADMISSION_ENFORCEMENT_CHECK 0
      set_default_if_unset APPLY_SIGNED_IMAGE_POLICY auto
      set_default_if_unset REQUIRE_SIGNED_IMAGE_POLICY 0
      set_default_if_unset RUN_AIMXS_BOUNDARY_CHECK 0
      ;;
    *)
      echo "Unsupported GATE_MODE='${GATE_MODE}' (expected full|fast)." >&2
      exit 1
      ;;
  esac
}

enforce_full_mode_contract() {
  if [ "${GATE_MODE}" != "full" ]; then
    return 0
  fi

  local mismatches=()

  check_required() {
    local var_name="$1"
    local expected="$2"
    local actual="${!var_name:-}"
    if [ "${actual}" != "${expected}" ]; then
      mismatches+=("${var_name}=${actual} (expected ${expected})")
    fi
  }

  check_required RUN_PHASE_04 1
  check_required RUN_PHASE_04_SECURE 1
  check_required RUN_M9_AUTHN_AUTHZ 1
  check_required RUN_M9_AUTHZ_TENANCY 1
  check_required RUN_M9_RBAC_MATRIX 1
  check_required RUN_M9_AUDIT_READ 1
  check_required RUN_M10_PROVIDER_CONFORMANCE 1
  check_required RUN_M10_POLICY_GRANT_ENFORCEMENT 1
  check_required RUN_M10_AIMXS_PRIVATE_RELEASE 1
  check_required RUN_M7_INTEGRATION 1
  check_required RUN_M7_BACKUP_RESTORE 1
  check_required RUN_M7_UPGRADE_SAFETY 1
  check_required RUN_PRODUCTION_PLACEHOLDER_CHECK 1
  check_required RUN_ROTATION_CHECK 1
  check_required FAIL_ON_NO_MTLS_REFS 1
  check_required RUN_HARDENING_BASELINE 1
  check_required RUN_ADMISSION_ENFORCEMENT_CHECK 1
  check_required APPLY_SIGNED_IMAGE_POLICY 1
  check_required REQUIRE_SIGNED_IMAGE_POLICY 1
  check_required RUN_AIMXS_BOUNDARY_CHECK 1
  check_required RUN_PROVENANCE_CHECK 1
  check_required PROVENANCE_STRICT 1

  if [ "${#mismatches[@]}" -gt 0 ]; then
    echo "GATE_MODE=full enforces required checks; use GATE_MODE=fast for local iteration overrides." >&2
    printf '  - %s\n' "${mismatches[@]}" >&2
    exit 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

dump_cluster_state() {
  echo
  echo "=== CI diagnostics (kind=${CLUSTER_NAME}) ===" >&2
  kubectl get nodes -o wide >&2 || true
  kubectl get ns >&2 || true
  kubectl -n cert-manager get deploy,pods >&2 || true
  kubectl -n argo-rollouts get deploy,pods >&2 || true
  kubectl -n argo-events get deploy,pods >&2 || true
  kubectl -n kserve get deploy,pods >&2 || true
  kubectl -n kuberay-system get deploy,pods >&2 || true
  kubectl -n kserve-smoke get inferenceservice,deploy,svc,pods,ingress >&2 || true
  kubectl -n kuberay-smoke get raycluster,svc,pods >&2 || true
}

cleanup_secure_fixture_resources() {
  if [ "${phase04_cleanup_secure_fixtures}" != "0" ] || [ "${secure_fixture_cleanup_done}" = "1" ]; then
    return 0
  fi

  echo "Cleaning secure fixture resources..."
  kubectl delete -k "${REPO_ROOT}/platform/tests/phase4-secure-mtls" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -k "${REPO_ROOT}/platform/tests/provider-discovery-mtls" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n epydios-system delete secret \
    epydios-controller-mtls-client \
    epydios-provider-ca \
    mtls-provider-server-tls \
    mtls-bearer-client-token \
    mtls-bearer-provider-token \
    --ignore-not-found >/dev/null 2>&1 || true

  secure_fixture_cleanup_done="1"
}

on_gate_exit() {
  cleanup_secure_fixture_resources
}

ensure_cluster() {
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    echo "kind cluster '${CLUSTER_NAME}' already exists; reusing it."
  else
    echo "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
}

main() {
  local m10_3_gate_executed=0
  trap dump_cluster_state ERR
  trap on_gate_exit EXIT

  apply_gate_mode_defaults
  enforce_full_mode_contract

  if [ "${RUN_PHASE_04_SECURE}" = "1" ] && [ "${RUN_ROTATION_CHECK}" = "1" ]; then
    phase04_cleanup_secure_fixtures="0"
  fi

  echo "Gate mode: ${GATE_MODE}"
  echo "Running mandatory QC preflight..."
  "${REPO_ROOT}/platform/ci/bin/qc-preflight.sh"
  if [ "${RUN_PRODUCTION_PLACEHOLDER_CHECK}" = "1" ]; then
    echo "Running production placeholder check..."
    "${REPO_ROOT}/platform/ci/bin/check-production-placeholders.sh"
  fi

  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  if [ "${RUN_ROTATION_CHECK}" = "1" ] || [ "${RUN_HARDENING_BASELINE}" = "1" ]; then
    require_cmd openssl
  fi
  if [ "${RUN_PROVENANCE_CHECK}" = "1" ]; then
    require_cmd go
  fi
  if [ "${RUN_AIMXS_BOUNDARY_CHECK}" = "1" ]; then
    require_cmd rg
  fi

  ensure_cluster

  if [ "${RUN_M7_INTEGRATION}" = "1" ]; then
    echo "Running M7.1 integration gate (M0->M5 critical path)..."
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    RUN_M0=1 \
    RUN_M0_BOOTSTRAP=1 \
    RUN_PHASE_00_01=1 \
    RUN_PHASE_02=1 \
    RUN_PHASE_03=1 \
    RUN_PHASE_03_FUNCTIONAL_SMOKE=1 \
    RUN_PHASE_04=1 \
    RUN_PHASE_04_SECURE="${RUN_PHASE_04_SECURE}" \
    RUN_PHASE_04_CLEANUP_SECURE_FIXTURES="${phase04_cleanup_secure_fixtures}" \
    RUN_PHASE_04_KSERVE_SMOKE=1 \
    RUN_PHASE_04_IMAGE_PREP=1 \
    RUN_M5=1 \
    RUN_M5_BOOTSTRAP=0 \
    RUN_M5_IMAGE_PREP=0 \
    RUN_M7_2_BACKUP_RESTORE="${RUN_M7_BACKUP_RESTORE}" \
    RUN_M7_3_UPGRADE_SAFETY="${RUN_M7_UPGRADE_SAFETY}" \
    USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
    AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
    FORCE_CONFLICTS="${FORCE_CONFLICTS}" \
      "${REPO_ROOT}/platform/local/bin/verify-m7-integration.sh"
  else
    if [ "${RUN_PHASE_00_01}" = "1" ]; then
      echo "Running Phase 00/01 runtime gate..."
      RUN_GATEWAY_API="${RUN_GATEWAY_API}" \
      USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
        AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
        "${REPO_ROOT}/platform/local/bin/verify-phase-00-01-runtime.sh"
    fi

    echo "Running Phase 03 gate (includes Phase 02 + functional smoke=${RUN_FUNCTIONAL_SMOKE})..."
    RUN_PHASE_02="${RUN_PHASE_02}" \
    RUN_FUNCTIONAL_SMOKE="${RUN_FUNCTIONAL_SMOKE}" \
    USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
    AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
    FORCE_CONFLICTS="${FORCE_CONFLICTS}" \
      "${REPO_ROOT}/platform/local/bin/verify-phase-03-kserve.sh"

    if [ "${RUN_PHASE_04}" = "1" ]; then
      echo "Running Phase 04 gate (provider selection + policy/evidence over KServe)..."
      RUNTIME=kind \
      CLUSTER_NAME="${CLUSTER_NAME}" \
      RUN_PHASE_03=0 \
      RUN_IMAGE_PREP=1 \
      RUN_KSERVE_SMOKE=1 \
      CLEANUP_SECURE_FIXTURES="${phase04_cleanup_secure_fixtures}" \
      RUN_SECURE_AUTH_PATH="${RUN_PHASE_04_SECURE}" \
        "${REPO_ROOT}/platform/local/bin/verify-phase-04-policy-evidence-kserve.sh"
    fi

    if [ "${RUN_PHASE_RUNTIME}" = "1" ]; then
      echo "Running M5 gate (runtime orchestration service)..."
      RUNTIME=kind \
      CLUSTER_NAME="${CLUSTER_NAME}" \
      RUN_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
      RUN_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
        "${REPO_ROOT}/platform/local/bin/verify-m5-runtime-orchestration.sh"
    fi

    if [ "${RUN_M7_BACKUP_RESTORE}" = "1" ]; then
      echo "Running M7.2 backup/restore drill..."
      NAMESPACE=epydios-system \
      CLUSTER_NAME=epydios-postgres \
        "${REPO_ROOT}/platform/local/bin/verify-m7-cnpg-backup-restore.sh"
    fi

    if [ "${RUN_M7_UPGRADE_SAFETY}" = "1" ]; then
      echo "Running M7.3 upgrade safety gate..."
      RUNTIME=kind \
      CLUSTER_NAME="${CLUSTER_NAME}" \
        "${REPO_ROOT}/platform/local/bin/verify-m7-upgrade-safety.sh"
    fi
  fi

  if [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ]; then
    echo "Running M9.1 gate (runtime API OIDC/JWT authn/authz skeleton)..."
    local run_m5_baseline_for_m9=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ]; then
      run_m5_baseline_for_m9=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m9}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
      "${REPO_ROOT}/platform/local/bin/verify-m9-authn-authz.sh"
  fi

  if [ "${RUN_M9_AUTHZ_TENANCY}" = "1" ]; then
    echo "Running M9.2/M9.3 gate (tenant/project authz scope + structured audit events)..."
    local run_m5_baseline_for_m9_scope=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ] || [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ]; then
      run_m5_baseline_for_m9_scope=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m9_scope}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
      "${REPO_ROOT}/platform/local/bin/verify-m9-authz-tenancy.sh"
  fi

  if [ "${RUN_M9_RBAC_MATRIX}" = "1" ]; then
    echo "Running M9.4 gate (OIDC role mapping + tenant/project RBAC policy matrix)..."
    local run_m5_baseline_for_m9_matrix=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ] || [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ] || [ "${RUN_M9_AUTHZ_TENANCY}" = "1" ]; then
      run_m5_baseline_for_m9_matrix=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m9_matrix}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
      "${REPO_ROOT}/platform/local/bin/verify-m9-rbac-matrix.sh"
  fi

  if [ "${RUN_M9_AUDIT_READ}" = "1" ]; then
    echo "Running M9.5 gate (runtime audit read endpoint + scoped filter assertions)..."
    local run_m5_baseline_for_m9_audit=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ] || [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ] || [ "${RUN_M9_AUTHZ_TENANCY}" = "1" ] || [ "${RUN_M9_RBAC_MATRIX}" = "1" ]; then
      run_m5_baseline_for_m9_audit=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m9_audit}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
      "${REPO_ROOT}/platform/local/bin/verify-m9-audit-read.sh"
  fi

  if [ "${RUN_M10_PROVIDER_CONFORMANCE}" = "1" ]; then
    echo "Running M10.1 gate (provider conformance matrix across auth modes)..."
    local run_m5_baseline_for_m10=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ] || [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ] || [ "${RUN_M9_AUTHZ_TENANCY}" = "1" ] || [ "${RUN_M9_RBAC_MATRIX}" = "1" ]; then
      run_m5_baseline_for_m10=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m10}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
    RUN_IMAGE_PREP=1 \
      "${REPO_ROOT}/platform/local/bin/verify-m10-provider-conformance.sh"
  fi

  if [ "${RUN_M10_POLICY_GRANT_ENFORCEMENT}" = "1" ]; then
    echo "Running M10.3 gate (policy grant token enforcement, no-token no-execution)..."
    local run_m5_baseline_for_m10_grant=1
    if [ "${RUN_M7_INTEGRATION}" = "1" ] || [ "${RUN_PHASE_RUNTIME}" = "1" ] || [ "${RUN_M9_AUTHN_AUTHZ}" = "1" ] || [ "${RUN_M9_AUTHZ_TENANCY}" = "1" ] || [ "${RUN_M9_RBAC_MATRIX}" = "1" ] || [ "${RUN_M10_PROVIDER_CONFORMANCE}" = "1" ]; then
      run_m5_baseline_for_m10_grant=0
    fi
    RUNTIME=kind \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    NAMESPACE=epydios-system \
    RUN_M5_BASELINE="${run_m5_baseline_for_m10_grant}" \
    RUN_M5_BOOTSTRAP="${RUN_PHASE_RUNTIME_BOOTSTRAP}" \
    RUN_M5_IMAGE_PREP="${RUN_PHASE_RUNTIME_IMAGE_PREP}" \
      "${REPO_ROOT}/platform/local/bin/verify-m10-policy-grant-enforcement.sh"
    m10_3_gate_executed=1
  fi

  if [ "${RUN_M10_AIMXS_PRIVATE_RELEASE}" = "1" ]; then
    echo "Running M10.2 gate (AIMXS first private release evidence + staging strict proof)..."
    M10_3_GATE_EXECUTED="${m10_3_gate_executed}" \
      "${REPO_ROOT}/platform/local/bin/verify-m10-aimxs-private-release.sh"
  fi

  if [ "${RUN_ROTATION_CHECK}" = "1" ]; then
    echo "Running secret/cert rotation check..."
    NAMESPACE=epydios-system \
    MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS}" \
    FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS}" \
      "${REPO_ROOT}/platform/local/bin/verify-secret-cert-rotation.sh"
  fi

  if [ "${RUN_PHASE_05}" = "1" ]; then
    echo "Running Phase 05 gate (KubeRay operator + CRD/API smoke)..."
    RUN_PHASE_03=0 \
    USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
    RUN_FUNCTIONAL_SMOKE="${RUN_PHASE_05_FUNCTIONAL_SMOKE}" \
      "${REPO_ROOT}/platform/local/bin/verify-phase-05-kuberay.sh"
  fi

  if [ "${RUN_HARDENING_BASELINE}" = "1" ]; then
    echo "Running production hardening baseline verification..."
    NAMESPACE=epydios-system \
    APPLY_NETWORK_POLICIES="${APPLY_NETWORK_POLICIES}" \
    APPLY_MONITORING_RESOURCES="${APPLY_MONITORING_RESOURCES}" \
    REQUIRE_MONITORING_CRDS="${REQUIRE_MONITORING_CRDS}" \
    RUN_ROTATION_CHECK="${RUN_ROTATION_CHECK}" \
    RUN_MONITORING_ALERT_SMOKE="${RUN_MONITORING_ALERT_SMOKE}" \
    AUTO_INSTALL_MONITORING_STACK="${AUTO_INSTALL_MONITORING_STACK}" \
    MONITORING_NAMESPACE="${MONITORING_NAMESPACE}" \
    MONITORING_RELEASE_NAME="${MONITORING_RELEASE_NAME}" \
    RUN_ADMISSION_ENFORCEMENT_CHECK="${RUN_ADMISSION_ENFORCEMENT_CHECK}" \
    APPLY_SIGNED_IMAGE_POLICY="${APPLY_SIGNED_IMAGE_POLICY}" \
    REQUIRE_SIGNED_IMAGE_POLICY="${REQUIRE_SIGNED_IMAGE_POLICY}" \
    MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS}" \
    FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS}" \
      "${REPO_ROOT}/platform/local/bin/verify-prod-hardening-baseline.sh"
  fi

  if [ "${RUN_AIMXS_BOUNDARY_CHECK}" = "1" ]; then
    echo "Running AIMXS external-boundary verification..."
    "${REPO_ROOT}/platform/local/bin/verify-aimxs-boundary.sh"
  fi

  if [ "${RUN_PROVENANCE_CHECK}" = "1" ]; then
    echo "Running provenance lock verification (strict=${PROVENANCE_STRICT})..."
    STRICT="${PROVENANCE_STRICT}" \
      "${REPO_ROOT}/platform/local/bin/verify-provenance-lockfiles.sh"
  fi

  cleanup_secure_fixture_resources

  echo
  echo "CI gate passed (${GATE_MODE} mode): Phase 00/01 + Phase 02 + Phase 03 + Phase 04 + M5 runtime + optional Phase 05 + provenance check."
}

main "$@"
