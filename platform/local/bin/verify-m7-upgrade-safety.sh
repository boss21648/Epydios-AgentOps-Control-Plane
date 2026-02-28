#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"
NAMESPACE="${NAMESPACE:-epydios-system}"

PREVIOUS_TAG="${PREVIOUS_TAG:-0.0.9}"
CURRENT_TAG="${CURRENT_TAG:-0.1.0}"
UPGRADE_POLICY_FILE="${UPGRADE_POLICY_FILE:-${REPO_ROOT}/platform/upgrade/compatibility-policy.yaml}"

RUN_PRECHECK_PHASE04="${RUN_PRECHECK_PHASE04:-1}"
RUN_POSTCHECK_PHASE04="${RUN_POSTCHECK_PHASE04:-1}"
RUN_POSTCHECK_M5="${RUN_POSTCHECK_M5:-1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-360}"

CONTROLLER_REPO="ghcr.io/epydios/epydios-extension-provider-registry-controller"
RUNTIME_REPO="ghcr.io/epydios/epydios-control-plane-runtime"
PROFILE_REPO="ghcr.io/epydios/epydios-oss-profile-static-resolver"
POLICY_REPO="ghcr.io/epydios/epydios-oss-policy-opa-provider"
EVIDENCE_REPO="ghcr.io/epydios/epydios-oss-evidence-memory-provider"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

dump_diagnostics() {
  echo
  echo "=== M7.3 diagnostics (${NAMESPACE}) ===" >&2
  kubectl -n "${NAMESPACE}" get deploy,pods,svc,extensionprovider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment extension-provider-registry-controller >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment orchestration-runtime >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment oss-profile-static-resolver >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment epydios-oss-policy-provider >&2 || true
  kubectl -n "${NAMESPACE}" describe deployment epydios-oss-evidence-provider >&2 || true
}
trap dump_diagnostics ERR

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
}

wait_for_rollout() {
  local name="$1"
  kubectl -n "${NAMESPACE}" rollout status "deployment/${name}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null
}

provider_ready_probed() {
  local provider="$1"
  local statuses
  statuses="$(
    kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
  )"
  printf '%s' "${statuses}" | grep -q 'Ready=True' && printf '%s' "${statuses}" | grep -q 'Probed=True'
}

wait_for_provider_ready_probed() {
  local provider="$1"
  local start
  start="$(date +%s)"
  while true; do
    if provider_ready_probed "${provider}"; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for provider Ready=True/Probed=True: ${provider}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o yaml >&2 || true
      return 1
    fi
    sleep 2
  done
}

ensure_cluster_context() {
  case "${RUNTIME}" in
    kind)
      require_cmd kind
      if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
        echo "kind cluster '${CLUSTER_NAME}' not found. Bootstrap first." >&2
        exit 1
      fi
      kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
      ;;
    k3d)
      require_cmd k3d
      kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
      ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac
}

is_upgrade_path_allowed() {
  local from="$1"
  local to="$2"
  awk -v from="${from}" -v to="${to}" '
    {
      if ($1 == "-" && $2 == "from:") {
        gsub(/"/, "", $3)
        cur_from = $3
      }
      if ($1 == "to:") {
        gsub(/"/, "", $2)
        cur_to = $2
        if (cur_from == from && cur_to == to) {
          ok = 1
        }
      }
    }
    END {
      exit(ok ? 0 : 1)
    }
  ' "${UPGRADE_POLICY_FILE}"
}

enforce_upgrade_policy() {
  if [ ! -f "${UPGRADE_POLICY_FILE}" ]; then
    echo "Upgrade policy file not found: ${UPGRADE_POLICY_FILE}" >&2
    exit 1
  fi
  if ! is_upgrade_path_allowed "${PREVIOUS_TAG}" "${CURRENT_TAG}"; then
    echo "Upgrade path not allowed by policy: ${PREVIOUS_TAG} -> ${CURRENT_TAG}" >&2
    echo "Policy file: ${UPGRADE_POLICY_FILE}" >&2
    exit 1
  fi
}

build_current_images() {
  INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 IMAGE_TAG="${CURRENT_TAG}" \
    "${SCRIPT_DIR}/build-local-images.sh"
}

retag_current_to_previous() {
  docker tag "${CONTROLLER_REPO}:${CURRENT_TAG}" "${CONTROLLER_REPO}:${PREVIOUS_TAG}"
  docker tag "${RUNTIME_REPO}:${CURRENT_TAG}" "${RUNTIME_REPO}:${PREVIOUS_TAG}"
  docker tag "${PROFILE_REPO}:${CURRENT_TAG}" "${PROFILE_REPO}:${PREVIOUS_TAG}"
  docker tag "${POLICY_REPO}:${CURRENT_TAG}" "${POLICY_REPO}:${PREVIOUS_TAG}"
  docker tag "${EVIDENCE_REPO}:${CURRENT_TAG}" "${EVIDENCE_REPO}:${PREVIOUS_TAG}"
}

load_upgrade_images() {
  case "${RUNTIME}" in
    kind)
      INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 IMAGE_TAG="${PREVIOUS_TAG}" CLUSTER_NAME="${CLUSTER_NAME}" \
        "${SCRIPT_DIR}/load-local-images-kind.sh"
      INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 IMAGE_TAG="${CURRENT_TAG}" CLUSTER_NAME="${CLUSTER_NAME}" \
        "${SCRIPT_DIR}/load-local-images-kind.sh"
      ;;
    k3d)
      INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 IMAGE_TAG="${PREVIOUS_TAG}" CLUSTER_NAME="${CLUSTER_NAME}" \
        "${SCRIPT_DIR}/load-local-images-k3d.sh"
      INCLUDE_POLICY_PROVIDER=1 INCLUDE_EVIDENCE_PROVIDER=1 IMAGE_TAG="${CURRENT_TAG}" CLUSTER_NAME="${CLUSTER_NAME}" \
        "${SCRIPT_DIR}/load-local-images-k3d.sh"
      ;;
  esac
}

apply_runtime_manifests() {
  kubectl apply -k "${REPO_ROOT}/platform/system"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-policy-opa"
  kubectl apply -k "${REPO_ROOT}/platform/providers/oss-evidence-memory"

  wait_for_deployment extension-provider-registry-controller
  wait_for_deployment orchestration-runtime
  wait_for_deployment oss-profile-static-resolver
  wait_for_deployment epydios-oss-policy-provider
  wait_for_deployment epydios-oss-evidence-provider
}

set_first_party_images_to_tag() {
  local tag="$1"
  kubectl -n "${NAMESPACE}" set image deployment/extension-provider-registry-controller \
    controller="${CONTROLLER_REPO}:${tag}" >/dev/null
  kubectl -n "${NAMESPACE}" set image deployment/orchestration-runtime \
    runtime="${RUNTIME_REPO}:${tag}" >/dev/null
  kubectl -n "${NAMESPACE}" set image deployment/oss-profile-static-resolver \
    profile-resolver="${PROFILE_REPO}:${tag}" >/dev/null
  kubectl -n "${NAMESPACE}" set image deployment/epydios-oss-policy-provider \
    policy-provider="${POLICY_REPO}:${tag}" >/dev/null
  kubectl -n "${NAMESPACE}" set image deployment/epydios-oss-evidence-provider \
    evidence-provider="${EVIDENCE_REPO}:${tag}" >/dev/null
}

wait_for_first_party_rollouts() {
  wait_for_rollout extension-provider-registry-controller
  wait_for_rollout orchestration-runtime
  wait_for_rollout oss-profile-static-resolver
  wait_for_rollout epydios-oss-policy-provider
  wait_for_rollout epydios-oss-evidence-provider
}

verify_provider_compatibility() {
  wait_for_provider_ready_probed oss-profile-static
  wait_for_provider_ready_probed oss-policy-opa
  wait_for_provider_ready_probed oss-evidence-memory
}

verify_crd_contract() {
  local served storage
  served="$(kubectl get crd extensionproviders.controlplane.epydios.ai -o jsonpath='{range .spec.versions[*]}{.name}:{.served}{";"}{end}')"
  storage="$(kubectl get crd extensionproviders.controlplane.epydios.ai -o jsonpath='{range .spec.versions[*]}{.name}:{.storage}{";"}{end}')"

  if ! printf '%s' "${served}" | grep -q 'v1alpha1:true'; then
    echo "CRD served versions missing v1alpha1:true: ${served}" >&2
    return 1
  fi
  if ! printf '%s' "${storage}" | grep -q 'v1alpha1:true'; then
    echo "CRD storage version missing v1alpha1:true: ${storage}" >&2
    return 1
  fi
}

run_phase04_precheck_if_enabled() {
  if [ "${RUN_PRECHECK_PHASE04}" != "1" ]; then
    return 0
  fi
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_PHASE_03=0 \
  RUN_PHASE_02=0 \
  RUN_IMAGE_PREP=0 \
  RUN_KSERVE_SMOKE=0 \
  RUN_SECURE_AUTH_PATH=0 \
    "${SCRIPT_DIR}/verify-phase-04-policy-evidence-kserve.sh"
}

run_phase04_postcheck_if_enabled() {
  if [ "${RUN_POSTCHECK_PHASE04}" != "1" ]; then
    return 0
  fi
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_PHASE_03=0 \
  RUN_PHASE_02=0 \
  RUN_IMAGE_PREP=0 \
  RUN_KSERVE_SMOKE=0 \
  RUN_SECURE_AUTH_PATH=0 \
    "${SCRIPT_DIR}/verify-phase-04-policy-evidence-kserve.sh"
}

run_m5_postcheck_if_enabled() {
  if [ "${RUN_POSTCHECK_M5}" != "1" ]; then
    return 0
  fi
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_BOOTSTRAP=0 \
  RUN_IMAGE_PREP=0 \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

main() {
  require_cmd kubectl
  require_cmd docker

  ensure_cluster_context
  enforce_upgrade_policy

  echo "M7.3: running pre-upgrade compatibility precheck..."
  run_phase04_precheck_if_enabled

  echo "M7.3: building current images (${CURRENT_TAG})..."
  build_current_images

  echo "M7.3: creating simulated N-1 tags (${PREVIOUS_TAG}) from current local images..."
  retag_current_to_previous

  echo "M7.3: loading N-1 and N images into cluster..."
  load_upgrade_images

  echo "M7.3: applying runtime manifests..."
  apply_runtime_manifests

  echo "M7.3: switching first-party deployments to N-1 (${PREVIOUS_TAG})..."
  set_first_party_images_to_tag "${PREVIOUS_TAG}"
  wait_for_first_party_rollouts
  verify_provider_compatibility
  verify_crd_contract

  echo "M7.3: upgrading first-party deployments to N (${CURRENT_TAG})..."
  set_first_party_images_to_tag "${CURRENT_TAG}"
  wait_for_first_party_rollouts
  verify_provider_compatibility
  verify_crd_contract

  echo "M7.3: running post-upgrade verification..."
  run_phase04_postcheck_if_enabled
  run_m5_postcheck_if_enabled

  echo
  echo "M7.3 upgrade safety gate passed."
  echo "  allowed_path=${PREVIOUS_TAG}->${CURRENT_TAG}"
  echo "  runtime=${RUNTIME}"
  echo "  cluster=${CLUSTER_NAME}"
}

main "$@"
