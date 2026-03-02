#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
NON_GITHUB_ROOT="${NON_GITHUB_ROOT:-${WORKSPACE_ROOT}/EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB}"

INPUT_FILE="${INPUT_FILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
STAGING_GATE_LOG_PATH="${STAGING_GATE_LOG_PATH:-}"

AIMXS_CUSTOMER_RELEASE_REF="${AIMXS_CUSTOMER_RELEASE_REF:-}"
AIMXS_CUSTOMER_PACKAGING_MODE="${AIMXS_CUSTOMER_PACKAGING_MODE:-}"
AIMXS_CUSTOMER_PRIMARY_IMAGE_REF="${AIMXS_CUSTOMER_PRIMARY_IMAGE_REF:-}"
AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST="${AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST:-}"
AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH="${AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH:-}"
AIMXS_CUSTOMER_SIGNATURE_EVIDENCE_REF="${AIMXS_CUSTOMER_SIGNATURE_EVIDENCE_REF:-}"
AIMXS_CUSTOMER_SBOM_EVIDENCE_REF="${AIMXS_CUSTOMER_SBOM_EVIDENCE_REF:-}"
AIMXS_CUSTOMER_AIRGAP_INSTALL_BUNDLE_REF="${AIMXS_CUSTOMER_AIRGAP_INSTALL_BUNDLE_REF:-}"
AIMXS_CUSTOMER_AIRGAP_UPDATE_BUNDLE_REF="${AIMXS_CUSTOMER_AIRGAP_UPDATE_BUNDLE_REF:-}"
AIMXS_CUSTOMER_SUPPORT_BOUNDARY_REF="${AIMXS_CUSTOMER_SUPPORT_BOUNDARY_REF:-}"
AIMXS_CUSTOMER_SLA_REF="${AIMXS_CUSTOMER_SLA_REF:-}"
AIMXS_CUSTOMER_SUPPORT_CONTACT_REF="${AIMXS_CUSTOMER_SUPPORT_CONTACT_REF:-}"
AIMXS_CUSTOMER_RELEASE_NOTES_REF="${AIMXS_CUSTOMER_RELEASE_NOTES_REF:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

normalize_existing_path() {
  local raw="$1"
  local candidate=""

  if [ -z "${raw}" ]; then
    return 1
  fi
  if [ -e "${raw}" ]; then
    candidate="${raw}"
  elif [ -e "${REPO_ROOT}/${raw}" ]; then
    candidate="${REPO_ROOT}/${raw}"
  elif [ -e "${WORKSPACE_ROOT}/${raw}" ]; then
    candidate="${WORKSPACE_ROOT}/${raw}"
  else
    return 1
  fi

  (
    cd "$(dirname "${candidate}")"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "${candidate}")"
  )
}

resolve_ref() {
  local raw="$1"
  local resolved
  resolved="$(normalize_existing_path "${raw}" || true)"
  if [ -n "${resolved}" ]; then
    printf '%s\n' "${resolved}"
  else
    printf '%s\n' "${raw}"
  fi
}

require_non_placeholder() {
  local value="$1"
  local label="$2"
  local lowered

  if [ -z "${value}" ]; then
    echo "Missing required value: ${label}" >&2
    exit 1
  fi
  lowered="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${lowered}" in
    *tbd*|*placeholder*|*changeme*|*example*)
      echo "Refusing placeholder value for ${label}: ${value}" >&2
      exit 1
      ;;
  esac
}

validate_sha256() {
  local digest="$1"
  local label="$2"
  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Invalid ${label}: ${digest}" >&2
    exit 1
  fi
  if [[ "${digest}" =~ ^sha256:0{64}$ ]]; then
    echo "Invalid ${label}: all-zero digest is not allowed." >&2
    exit 1
  fi
}

load_inputs() {
  if [ -z "${INPUT_FILE}" ]; then
    if [ -f "${NON_GITHUB_ROOT}/provenance/aimxs/customer-hosted-release-inputs.vars" ]; then
      INPUT_FILE="${NON_GITHUB_ROOT}/provenance/aimxs/customer-hosted-release-inputs.vars"
    else
      INPUT_FILE="${REPO_ROOT}/provenance/aimxs/customer-hosted-release-inputs.vars"
    fi
  fi

  if [ ! -f "${INPUT_FILE}" ]; then
    echo "Missing customer-hosted packaging inputs file: ${INPUT_FILE}" >&2
    echo "Create ../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/customer-hosted-release-inputs.vars" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  . "${INPUT_FILE}"
}

find_staging_log() {
  local candidate

  if [ -n "${STAGING_GATE_LOG_PATH}" ]; then
    STAGING_GATE_LOG_PATH="$(normalize_existing_path "${STAGING_GATE_LOG_PATH}" || true)"
  else
    while IFS= read -r candidate; do
      [ -n "${candidate}" ] || continue
      if grep -Fq "CI gate passed (full mode)" "${candidate}" \
        && grep -Fq "Running M10.4 gate (three deployment modes on a single provider contract)..." "${candidate}" \
        && grep -Fq "Running M10.5 gate (customer-hosted local AIMXS no-egress proof)..." "${candidate}" \
        && grep -Fq "Running M10.6 gate (AIMXS entitlement deny path + licensed ALLOW assertions)..." "${candidate}"; then
        STAGING_GATE_LOG_PATH="${candidate}"
        break
      fi
    done < <(
      ls -t \
        "${NON_GITHUB_ROOT}/provenance/promotion/staging-full-gate-"*.log \
        "${REPO_ROOT}/provenance/promotion/staging-full-gate-"*.log 2>/dev/null || true
    )
  fi

  if [ -z "${STAGING_GATE_LOG_PATH}" ] || [ ! -f "${STAGING_GATE_LOG_PATH}" ]; then
    echo "Missing strict staging log with M10.4/M10.5/M10.6 markers." >&2
    exit 1
  fi
}

assert_log_contains() {
  local pattern="$1"
  if ! grep -Fq "${pattern}" "${STAGING_GATE_LOG_PATH}"; then
    echo "Staging log assertion failed: '${pattern}' not found in ${STAGING_GATE_LOG_PATH}" >&2
    exit 1
  fi
}

assert_runbook_content() {
  local file="$1"
  local label="$2"
  shift 2
  if [ ! -f "${file}" ]; then
    echo "Missing runbook: ${file}" >&2
    exit 1
  fi
  local pattern
  for pattern in "$@"; do
    if ! grep -Eiq "${pattern}" "${file}"; then
      echo "Runbook content assertion failed (${label}): missing pattern '${pattern}' in ${file}" >&2
      exit 1
    fi
  done
}

main() {
  require_cmd jq
  require_cmd grep
  require_cmd awk

  load_inputs
  find_staging_log

  if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="${NON_GITHUB_ROOT}/provenance/aimxs"
  fi
  mkdir -p "${OUTPUT_DIR}"

  local airgap_doc support_doc
  airgap_doc="${REPO_ROOT}/docs/runbooks/aimxs-customer-hosted-airgap.md"
  support_doc="${REPO_ROOT}/docs/runbooks/aimxs-customer-hosted-support-boundary.md"

  assert_runbook_content "${airgap_doc}" "airgap" "air-?gapped" "no external egress" "update flow" "rollback"
  assert_runbook_content "${support_doc}" "support-boundary" "support boundary" "sla" "incident" "shared responsibility"

  assert_log_contains "Running M10.4 gate (three deployment modes on a single provider contract)..."
  assert_log_contains "Running M10.5 gate (customer-hosted local AIMXS no-egress proof)..."
  assert_log_contains "Running M10.6 gate (AIMXS entitlement deny path + licensed ALLOW assertions)..."
  assert_log_contains "CI gate passed (full mode)"

  require_non_placeholder "${AIMXS_CUSTOMER_RELEASE_REF}" "AIMXS_CUSTOMER_RELEASE_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_PACKAGING_MODE}" "AIMXS_CUSTOMER_PACKAGING_MODE"
  require_non_placeholder "${AIMXS_CUSTOMER_SIGNATURE_EVIDENCE_REF}" "AIMXS_CUSTOMER_SIGNATURE_EVIDENCE_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_SBOM_EVIDENCE_REF}" "AIMXS_CUSTOMER_SBOM_EVIDENCE_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_AIRGAP_INSTALL_BUNDLE_REF}" "AIMXS_CUSTOMER_AIRGAP_INSTALL_BUNDLE_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_AIRGAP_UPDATE_BUNDLE_REF}" "AIMXS_CUSTOMER_AIRGAP_UPDATE_BUNDLE_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_SUPPORT_BOUNDARY_REF}" "AIMXS_CUSTOMER_SUPPORT_BOUNDARY_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_SLA_REF}" "AIMXS_CUSTOMER_SLA_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_SUPPORT_CONTACT_REF}" "AIMXS_CUSTOMER_SUPPORT_CONTACT_REF"
  require_non_placeholder "${AIMXS_CUSTOMER_RELEASE_NOTES_REF}" "AIMXS_CUSTOMER_RELEASE_NOTES_REF"

  local packaging_mode normalized_mode primary_ref primary_digest
  packaging_mode="$(printf '%s' "${AIMXS_CUSTOMER_PACKAGING_MODE}" | tr '[:upper:]' '[:lower:]' | xargs)"
  normalized_mode="${packaging_mode}"
  primary_ref=""
  primary_digest=""

  case "${normalized_mode}" in
    image)
      require_non_placeholder "${AIMXS_CUSTOMER_PRIMARY_IMAGE_REF}" "AIMXS_CUSTOMER_PRIMARY_IMAGE_REF"
      require_non_placeholder "${AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST}" "AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST"
      validate_sha256 "${AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST}" "AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST"
      primary_ref="$(resolve_ref "${AIMXS_CUSTOMER_PRIMARY_IMAGE_REF}")"
      primary_digest="${AIMXS_CUSTOMER_PRIMARY_IMAGE_DIGEST}"
      ;;
    artifact)
      require_non_placeholder "${AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH}" "AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH"
      primary_ref="$(normalize_existing_path "${AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH}" || true)"
      if [ -z "${primary_ref}" ] || [ ! -f "${primary_ref}" ]; then
        echo "AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH is missing or unreadable: ${AIMXS_CUSTOMER_PRIMARY_ARTIFACT_PATH}" >&2
        exit 1
      fi
      primary_digest="sha256:$(sha256_file "${primary_ref}")"
      ;;
    *)
      echo "Unsupported AIMXS_CUSTOMER_PACKAGING_MODE='${AIMXS_CUSTOMER_PACKAGING_MODE}' (expected image|artifact)." >&2
      exit 1
      ;;
  esac

  local timestamp out_json out_sha latest_json latest_sha staging_log_sha
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out_json="${OUTPUT_DIR}/m10-7-customer-hosted-packaging-evidence-${timestamp}.json"
  latest_json="${OUTPUT_DIR}/m10-7-customer-hosted-packaging-evidence-latest.json"
  staging_log_sha="$(sha256_file "${STAGING_GATE_LOG_PATH}")"

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg release_ref "${AIMXS_CUSTOMER_RELEASE_REF}" \
    --arg packaging_mode "${normalized_mode}" \
    --arg primary_ref "${primary_ref}" \
    --arg primary_digest "${primary_digest}" \
    --arg signature_ref "$(resolve_ref "${AIMXS_CUSTOMER_SIGNATURE_EVIDENCE_REF}")" \
    --arg sbom_ref "$(resolve_ref "${AIMXS_CUSTOMER_SBOM_EVIDENCE_REF}")" \
    --arg install_bundle_ref "$(resolve_ref "${AIMXS_CUSTOMER_AIRGAP_INSTALL_BUNDLE_REF}")" \
    --arg update_bundle_ref "$(resolve_ref "${AIMXS_CUSTOMER_AIRGAP_UPDATE_BUNDLE_REF}")" \
    --arg support_boundary_ref "$(resolve_ref "${AIMXS_CUSTOMER_SUPPORT_BOUNDARY_REF}")" \
    --arg sla_ref "$(resolve_ref "${AIMXS_CUSTOMER_SLA_REF}")" \
    --arg support_contact_ref "${AIMXS_CUSTOMER_SUPPORT_CONTACT_REF}" \
    --arg release_notes_ref "$(resolve_ref "${AIMXS_CUSTOMER_RELEASE_NOTES_REF}")" \
    --arg staging_log_path "${STAGING_GATE_LOG_PATH}" \
    --arg staging_log_sha "sha256:${staging_log_sha}" \
    --arg input_file "${INPUT_FILE}" \
    --arg airgap_doc "${airgap_doc}" \
    --arg support_doc "${support_doc}" \
    '{
      schema_version: 1,
      milestone: "M10.7",
      title: "AIMXS customer-hosted packaging evidence",
      generated_at_utc: $generated_at,
      source_inputs: { file: $input_file },
      release: {
        release_ref: $release_ref,
        packaging_mode: $packaging_mode,
        primary_ref: $primary_ref,
        primary_digest: $primary_digest,
        signature_evidence_ref: $signature_ref,
        sbom_evidence_ref: $sbom_ref,
        release_notes_ref: $release_notes_ref
      },
      airgap: {
        install_bundle_ref: $install_bundle_ref,
        update_bundle_ref: $update_bundle_ref,
        runbook: $airgap_doc
      },
      support: {
        support_boundary_ref: $support_boundary_ref,
        sla_ref: $sla_ref,
        support_contact_ref: $support_contact_ref,
        runbook: $support_doc
      },
      strict_staging_proof: {
        log_path: $staging_log_path,
        log_sha256: $staging_log_sha,
        required_markers: [
          "Running M10.4 gate (three deployment modes on a single provider contract)...",
          "Running M10.5 gate (customer-hosted local AIMXS no-egress proof)...",
          "Running M10.6 gate (AIMXS entitlement deny path + licensed ALLOW assertions)...",
          "CI gate passed (full mode)"
        ]
      }
    }' > "${out_json}"

  out_sha="$(sha256_file "${out_json}")"
  printf '%s  %s\n' "${out_sha}" "$(basename "${out_json}")" > "${out_json}.sha256"

  cp "${out_json}" "${latest_json}"
  cp "${out_json}.sha256" "${latest_json}.sha256"

  echo "M10.7 customer-hosted packaging evidence verification passed."
  echo "  evidence=${out_json}"
  echo "  evidence_sha256=sha256:${out_sha}"
  echo "  staging_log=${STAGING_GATE_LOG_PATH}"
  echo "  packaging_mode=${normalized_mode}"
}

main "$@"
