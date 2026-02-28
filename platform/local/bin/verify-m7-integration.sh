#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNTIME="${RUNTIME:-kind}" # kind | k3d
CLUSTER_NAME="${CLUSTER_NAME:-epydios-dev}"

RUN_M0="${RUN_M0:-1}"
RUN_M0_BOOTSTRAP="${RUN_M0_BOOTSTRAP:-1}"

RUN_PHASE_00_01="${RUN_PHASE_00_01:-1}"
RUN_PHASE_02="${RUN_PHASE_02:-1}"
RUN_PHASE_03="${RUN_PHASE_03:-1}"
RUN_PHASE_03_FUNCTIONAL_SMOKE="${RUN_PHASE_03_FUNCTIONAL_SMOKE:-1}"

RUN_PHASE_04="${RUN_PHASE_04:-1}"
RUN_PHASE_04_SECURE="${RUN_PHASE_04_SECURE:-1}"
RUN_PHASE_04_KSERVE_SMOKE="${RUN_PHASE_04_KSERVE_SMOKE:-1}"
RUN_PHASE_04_IMAGE_PREP="${RUN_PHASE_04_IMAGE_PREP:-1}"
RUN_PHASE_04_CLEANUP_SECURE_FIXTURES="${RUN_PHASE_04_CLEANUP_SECURE_FIXTURES:-1}"

RUN_M5="${RUN_M5:-1}"
RUN_M5_BOOTSTRAP="${RUN_M5_BOOTSTRAP:-0}"
RUN_M5_IMAGE_PREP="${RUN_M5_IMAGE_PREP:-0}"
RUN_M7_2_BACKUP_RESTORE="${RUN_M7_2_BACKUP_RESTORE:-0}"
RUN_M7_3_UPGRADE_SAFETY="${RUN_M7_3_UPGRADE_SAFETY:-0}"

USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-0}"
AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-1}"
FORCE_CONFLICTS="${FORCE_CONFLICTS:-1}"

CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"

step_results=()
step_details=()

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

record_step() {
  local step="$1"
  local status="$2"
  local detail="$3"
  step_results+=("${step}:${status}")
  step_details+=("${step}:${detail}")
}

print_summary() {
  local overall="PASS"
  local i pair name status detail

  for pair in "${step_results[@]}"; do
    status="${pair##*:}"
    if [ "${status}" != "PASS" ]; then
      overall="FAIL"
    fi
  done

  echo
  echo "M7.1 Integration Summary (${RUNTIME}, cluster=${CLUSTER_NAME})"
  echo "------------------------------------------------------------"
  for i in "${!step_results[@]}"; do
    pair="${step_results[$i]}"
    name="${pair%%:*}"
    status="${pair##*:}"
    detail="${step_details[$i]#*:}"
    printf '%-34s %s\n' "${name}" "${status}"
    printf '  %s\n' "${detail}"
  done
  echo "------------------------------------------------------------"
  printf '%-34s %s\n' "overall" "${overall}"

  [ "${overall}" = "PASS" ]
}

run_step() {
  local step="$1"
  shift

  echo "Running ${step}..."
  if "$@"; then
    record_step "${step}" "PASS" "completed"
    return 0
  fi

  record_step "${step}" "FAIL" "failed (see logs above)"
  if [ "${CONTINUE_ON_ERROR}" = "1" ]; then
    return 0
  fi
  return 1
}

run_m0_step() {
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_BOOTSTRAP="${RUN_M0_BOOTSTRAP}" \
    "${SCRIPT_DIR}/verify-m0.sh"
}

run_phase_00_01_step() {
  RUN_GATEWAY_API=1 \
  USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
  AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
    "${SCRIPT_DIR}/verify-phase-00-01-runtime.sh"
}

run_phase_03_step() {
  RUN_PHASE_02="${RUN_PHASE_02}" \
  RUN_FUNCTIONAL_SMOKE="${RUN_PHASE_03_FUNCTIONAL_SMOKE}" \
  USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
  AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
  FORCE_CONFLICTS="${FORCE_CONFLICTS}" \
    "${SCRIPT_DIR}/verify-phase-03-kserve.sh"
}

run_phase_04_step() {
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_PHASE_03=0 \
  RUN_PHASE_02=0 \
  RUN_IMAGE_PREP="${RUN_PHASE_04_IMAGE_PREP}" \
  RUN_KSERVE_SMOKE="${RUN_PHASE_04_KSERVE_SMOKE}" \
  RUN_SECURE_AUTH_PATH="${RUN_PHASE_04_SECURE}" \
  CLEANUP_SECURE_FIXTURES="${RUN_PHASE_04_CLEANUP_SECURE_FIXTURES}" \
  USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
  AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER}" \
  FORCE_CONFLICTS="${FORCE_CONFLICTS}" \
    "${SCRIPT_DIR}/verify-phase-04-policy-evidence-kserve.sh"
}

run_m5_step() {
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_BOOTSTRAP="${RUN_M5_BOOTSTRAP}" \
  RUN_IMAGE_PREP="${RUN_M5_IMAGE_PREP}" \
    "${SCRIPT_DIR}/verify-m5-runtime-orchestration.sh"
}

run_m7_2_backup_restore_step() {
  NAMESPACE=epydios-system \
  CLUSTER_NAME=epydios-postgres \
    "${SCRIPT_DIR}/verify-m7-cnpg-backup-restore.sh"
}

run_m7_3_upgrade_safety_step() {
  RUNTIME="${RUNTIME}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  RUN_PRECHECK_PHASE04=0 \
  RUN_POSTCHECK_PHASE04=0 \
  RUN_POSTCHECK_M5=0 \
    "${SCRIPT_DIR}/verify-m7-upgrade-safety.sh"
}

main() {
  require_cmd kubectl

  if [ "${RUN_M5}" = "1" ] && [ "${RUN_PHASE_04}" != "1" ] && [ "${RUN_M5_IMAGE_PREP}" = "0" ]; then
    echo "RUN_PHASE_04=0 and RUN_M5_IMAGE_PREP=0; forcing RUN_M5_IMAGE_PREP=1 for runtime image availability."
    RUN_M5_IMAGE_PREP=1
  fi

  case "${RUNTIME}" in
    kind)
      if [ "${RUN_M0}" = "1" ] || [ "${RUN_M5_BOOTSTRAP}" = "1" ]; then
        require_cmd kind
      fi
      ;;
    k3d)
      if [ "${RUN_M0}" = "1" ] || [ "${RUN_M5_BOOTSTRAP}" = "1" ]; then
        require_cmd k3d
      fi
      ;;
    *)
      echo "Unsupported RUNTIME='${RUNTIME}' (expected kind|k3d)." >&2
      exit 1
      ;;
  esac

  if [ "${RUN_M0}" = "1" ] || [ "${RUN_PHASE_00_01}" = "1" ] || [ "${RUN_M5_BOOTSTRAP}" = "1" ]; then
    require_cmd helm
    require_cmd docker
  fi

  if [ "${RUN_M0}" = "1" ]; then
    run_step "m0_bootstrap_discovery" run_m0_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_PHASE_00_01}" = "1" ]; then
    run_step "phase_00_01_runtime" run_phase_00_01_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_PHASE_03}" = "1" ]; then
    run_step "phase_03_kserve" run_phase_03_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_PHASE_04}" = "1" ]; then
    run_step "phase_04_policy_evidence" run_phase_04_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_M5}" = "1" ]; then
    run_step "m5_runtime_orchestration" run_m5_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_M7_2_BACKUP_RESTORE}" = "1" ]; then
    run_step "m7_2_backup_restore" run_m7_2_backup_restore_step || {
      print_summary
      exit 1
    }
  fi

  if [ "${RUN_M7_3_UPGRADE_SAFETY}" = "1" ]; then
    run_step "m7_3_upgrade_safety" run_m7_3_upgrade_safety_step || {
      print_summary
      exit 1
    }
  fi

  print_summary
}

main "$@"
