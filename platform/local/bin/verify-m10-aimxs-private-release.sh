#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
NON_GITHUB_ROOT="${NON_GITHUB_ROOT:-${WORKSPACE_ROOT}/EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB}"

EVIDENCE_INPUT_FILE="${EVIDENCE_INPUT_FILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
STAGING_GATE_LOG_PATH="${STAGING_GATE_LOG_PATH:-}"
RUN_BOUNDARY_CHECK="${RUN_BOUNDARY_CHECK:-1}"
M10_3_GATE_EXECUTED="${M10_3_GATE_EXECUTED:-0}"

M10_3_LOG_IN_STAGING="0"

AIMXS_PRIVATE_SDK_RELEASE_TAG="${AIMXS_PRIVATE_SDK_RELEASE_TAG:-}"
AIMXS_PRIVATE_SDK_ARTIFACT_PATH="${AIMXS_PRIVATE_SDK_ARTIFACT_PATH:-}"
AIMXS_PRIVATE_PROVIDER_RELEASE_REF="${AIMXS_PRIVATE_PROVIDER_RELEASE_REF:-}"
AIMXS_PRIVATE_PROVIDER_IMAGE_REF="${AIMXS_PRIVATE_PROVIDER_IMAGE_REF:-}"
AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST="${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST:-}"
AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH="${AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH:-}"
AIMXS_PRIVATE_RELEASE_NOTES_REF="${AIMXS_PRIVATE_RELEASE_NOTES_REF:-}"

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

file_size_bytes() {
  local file="$1"
  if stat -f '%z' "${file}" >/dev/null 2>&1; then
    stat -f '%z' "${file}"
  else
    stat -c '%s' "${file}"
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
  if [ -z "${EVIDENCE_INPUT_FILE}" ]; then
    if [ -f "${NON_GITHUB_ROOT}/provenance/aimxs/private-release-inputs.vars" ]; then
      EVIDENCE_INPUT_FILE="${NON_GITHUB_ROOT}/provenance/aimxs/private-release-inputs.vars"
    else
      EVIDENCE_INPUT_FILE="${REPO_ROOT}/provenance/aimxs/private-release-inputs.vars"
    fi
  fi

  if [ ! -f "${EVIDENCE_INPUT_FILE}" ]; then
    return 0
  fi

  # shellcheck disable=SC1090
  . "${EVIDENCE_INPUT_FILE}"
}

find_staging_log() {
  local strict_latest
  local fallback_latest
  local candidate
  local latest_any

  if [ -n "${STAGING_GATE_LOG_PATH}" ]; then
    STAGING_GATE_LOG_PATH="$(normalize_existing_path "${STAGING_GATE_LOG_PATH}" || true)"
    if grep -Fq "Running M10.3 gate (policy grant token enforcement, no-token no-execution)..." "${STAGING_GATE_LOG_PATH}" 2>/dev/null; then
      M10_3_LOG_IN_STAGING="1"
    fi
  else
    while IFS= read -r candidate; do
      [ -n "${candidate}" ] || continue
      if grep -Fq "CI gate passed (full mode)" "${candidate}" \
        && grep -Fq "AIMXS boundary verification passed." "${candidate}" \
        && grep -Fq "Running M10.1 gate (provider conformance matrix across auth modes)..." "${candidate}"; then
        if grep -Fq "Running M10.3 gate (policy grant token enforcement, no-token no-execution)..." "${candidate}"; then
          strict_latest="${candidate}"
          break
        fi
        if [ -z "${fallback_latest}" ]; then
          fallback_latest="${candidate}"
        fi
      fi
    done < <(
      ls -t \
        "${NON_GITHUB_ROOT}/provenance/promotion/staging-full-gate-"*.log \
        "${REPO_ROOT}/provenance/promotion/staging-full-gate-"*.log 2>/dev/null || true
    )

    if [ -n "${strict_latest}" ]; then
      STAGING_GATE_LOG_PATH="${strict_latest}"
      M10_3_LOG_IN_STAGING="1"
    elif [ -n "${fallback_latest}" ]; then
      STAGING_GATE_LOG_PATH="${fallback_latest:-}"
      M10_3_LOG_IN_STAGING="0"
    elif [ "${M10_3_GATE_EXECUTED}" = "1" ]; then
      latest_any="$(
        ls -t \
          "${NON_GITHUB_ROOT}/provenance/promotion/staging-full-gate-"*.log \
          "${REPO_ROOT}/provenance/promotion/staging-full-gate-"*.log 2>/dev/null | head -n1 || true
      )"
      STAGING_GATE_LOG_PATH="${latest_any:-}"
      if grep -Fq "Running M10.3 gate (policy grant token enforcement, no-token no-execution)..." "${STAGING_GATE_LOG_PATH}" 2>/dev/null; then
        M10_3_LOG_IN_STAGING="1"
      else
        M10_3_LOG_IN_STAGING="0"
      fi
    fi
  fi

  if [ -z "${STAGING_GATE_LOG_PATH}" ] || [ ! -f "${STAGING_GATE_LOG_PATH}" ]; then
    echo "Missing completed staging strict gate log. Set STAGING_GATE_LOG_PATH or run PROFILE=staging-full gate first." >&2
    exit 1
  fi
}

assert_log_contains() {
  local pattern="$1"
  local label="$2"
  local line
  line="$(grep -n -m1 -F "${pattern}" "${STAGING_GATE_LOG_PATH}" | cut -d: -f1 || true)"
  if [ -z "${line}" ]; then
    echo "Staging log assertion failed (${label}): '${pattern}' not found in ${STAGING_GATE_LOG_PATH}" >&2
    exit 1
  fi
  printf '%s\n' "${line}"
}

main() {
  require_cmd jq
  require_cmd grep
  require_cmd awk

  if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="${NON_GITHUB_ROOT}/provenance/aimxs"
  fi

  load_inputs
  mkdir -p "${OUTPUT_DIR}"

  require_non_placeholder "${AIMXS_PRIVATE_SDK_RELEASE_TAG}" "AIMXS_PRIVATE_SDK_RELEASE_TAG"
  require_non_placeholder "${AIMXS_PRIVATE_PROVIDER_RELEASE_REF}" "AIMXS_PRIVATE_PROVIDER_RELEASE_REF"
  require_non_placeholder "${AIMXS_PRIVATE_RELEASE_NOTES_REF}" "AIMXS_PRIVATE_RELEASE_NOTES_REF"

  local sdk_artifact_abs provider_artifact_abs provider_mode provider_digest
  sdk_artifact_abs="$(normalize_existing_path "${AIMXS_PRIVATE_SDK_ARTIFACT_PATH}" || true)"
  if [ -z "${sdk_artifact_abs}" ] || [ ! -f "${sdk_artifact_abs}" ]; then
    echo "AIMXS SDK artifact path is missing or unreadable: ${AIMXS_PRIVATE_SDK_ARTIFACT_PATH}" >&2
    exit 1
  fi

  provider_mode=""
  provider_artifact_abs=""
  provider_digest=""

  if [ -n "${AIMXS_PRIVATE_PROVIDER_IMAGE_REF}" ] || [ -n "${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST}" ]; then
    require_non_placeholder "${AIMXS_PRIVATE_PROVIDER_IMAGE_REF}" "AIMXS_PRIVATE_PROVIDER_IMAGE_REF"
    require_non_placeholder "${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST}" "AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST"
    validate_sha256 "${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST}" "AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST"
    provider_mode="image"
    provider_digest="${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST#sha256:}"
  elif [ -n "${AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH}" ]; then
    provider_artifact_abs="$(normalize_existing_path "${AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH}" || true)"
    if [ -z "${provider_artifact_abs}" ] || [ ! -f "${provider_artifact_abs}" ]; then
      echo "AIMXS provider artifact path is missing or unreadable: ${AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH}" >&2
      exit 1
    fi
    provider_mode="artifact"
    provider_digest="$(sha256_file "${provider_artifact_abs}")"
  else
    echo "Provide either AIMXS_PRIVATE_PROVIDER_IMAGE_REF + AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST or AIMXS_PRIVATE_PROVIDER_ARTIFACT_PATH." >&2
    exit 1
  fi

  if [ "${RUN_BOUNDARY_CHECK}" = "1" ]; then
    "${SCRIPT_DIR}/verify-aimxs-boundary.sh"
  fi

  find_staging_log

  local line_m101 line_m103 line_boundary_pass line_gate_pass
  line_m101="$(assert_log_contains "Running M10.1 gate (provider conformance matrix across auth modes)..." "m10_1_gate")"
  line_boundary_pass="$(assert_log_contains "AIMXS boundary verification passed." "aimxs_boundary_pass")"
  if [ "${M10_3_GATE_EXECUTED}" = "1" ]; then
    line_gate_pass="$(grep -n -m1 -F "CI gate passed (full mode)" "${STAGING_GATE_LOG_PATH}" | cut -d: -f1 || true)"
  else
    line_gate_pass="$(assert_log_contains "CI gate passed (full mode)" "full_gate_pass")"
  fi

  line_m103=""
  if [ "${M10_3_LOG_IN_STAGING}" = "1" ]; then
    line_m103="$(assert_log_contains "Running M10.3 gate (policy grant token enforcement, no-token no-execution)..." "m10_3_gate")"
  elif [ "${M10_3_GATE_EXECUTED}" != "1" ]; then
    echo "Staging log ${STAGING_GATE_LOG_PATH} does not include M10.3 marker and current run did not declare M10.3 execution." >&2
    echo "Run PROFILE=staging-full gate once after M10.3 wiring or pass M10_3_GATE_EXECUTED=1 when invoking from CI gate." >&2
    exit 1
  fi

  local staging_log_sha staging_log_size sdk_sha now_utc
  staging_log_sha="$(sha256_file "${STAGING_GATE_LOG_PATH}")"
  staging_log_size="$(file_size_bytes "${STAGING_GATE_LOG_PATH}")"
  sdk_sha="$(sha256_file "${sdk_artifact_abs}")"
  now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local assertions_json
  if [ "${M10_3_LOG_IN_STAGING}" = "1" ]; then
    assertions_json="$(
      jq -n \
        --arg line_m101 "${line_m101}" \
        --arg line_m103 "${line_m103}" \
        --arg line_boundary_pass "${line_boundary_pass}" \
        --arg line_gate_pass "${line_gate_pass}" \
        '[
          {
            name: "m10_1_gate_invoked",
            contains: "Running M10.1 gate (provider conformance matrix across auth modes)...",
            line: ($line_m101 | tonumber)
          },
          {
            name: "m10_3_gate_invoked",
            contains: "Running M10.3 gate (policy grant token enforcement, no-token no-execution)...",
            line: ($line_m103 | tonumber)
          },
          {
            name: "aimxs_boundary_passed",
            contains: "AIMXS boundary verification passed.",
            line: ($line_boundary_pass | tonumber)
          },
          {
            name: "full_gate_passed",
            contains: "CI gate passed (full mode)",
            line: (if ($line_gate_pass | length) > 0 then ($line_gate_pass | tonumber) else null end)
          }
        ]'
    )"
  else
    assertions_json="$(
      jq -n \
        --arg line_m101 "${line_m101}" \
        --arg line_boundary_pass "${line_boundary_pass}" \
        --arg line_gate_pass "${line_gate_pass}" \
        '[
          {
            name: "m10_1_gate_invoked",
            contains: "Running M10.1 gate (provider conformance matrix across auth modes)...",
            line: ($line_m101 | tonumber)
          },
          {
            name: "m10_3_gate_invoked_current_run",
            contains: "M10_3_GATE_EXECUTED=1 (current gate execution)",
            line: null
          },
          {
            name: "aimxs_boundary_passed",
            contains: "AIMXS boundary verification passed.",
            line: ($line_boundary_pass | tonumber)
          },
          {
            name: "full_gate_passed",
            contains: "CI gate passed (full mode)",
            line: (if ($line_gate_pass | length) > 0 then ($line_gate_pass | tonumber) else null end)
          }
        ]'
    )"
  fi

  local timestamp output_json latest_json
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  output_json="${OUTPUT_DIR}/m10-2-private-release-evidence-${timestamp}.json"
  latest_json="${OUTPUT_DIR}/m10-2-private-release-evidence-latest.json"

  jq -n \
    --arg generated_at "${now_utc}" \
    --arg staging_log_path "${STAGING_GATE_LOG_PATH}" \
    --arg staging_log_sha "${staging_log_sha}" \
    --argjson staging_log_size "${staging_log_size}" \
    --arg sdk_tag "${AIMXS_PRIVATE_SDK_RELEASE_TAG}" \
    --arg sdk_artifact_path "${sdk_artifact_abs}" \
    --arg sdk_artifact_sha "${sdk_sha}" \
    --arg provider_mode "${provider_mode}" \
    --arg provider_release_ref "${AIMXS_PRIVATE_PROVIDER_RELEASE_REF}" \
    --arg provider_image_ref "${AIMXS_PRIVATE_PROVIDER_IMAGE_REF}" \
    --arg provider_image_digest "${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST}" \
    --arg provider_artifact_path "${provider_artifact_abs}" \
    --arg provider_artifact_sha "${provider_digest}" \
    --arg release_notes_ref "${AIMXS_PRIVATE_RELEASE_NOTES_REF}" \
    --arg evidence_input_file "${EVIDENCE_INPUT_FILE}" \
    --argjson assertions "${assertions_json}" \
    '
    {
      schema_version: 1,
      milestone: "M10.2",
      title: "AIMXS first private release evidence",
      generated_at_utc: $generated_at,
      release_notes_ref: $release_notes_ref,
      source_inputs: {
        file: $evidence_input_file
      },
      sdk_release: {
        tag: $sdk_tag,
        artifact_path: $sdk_artifact_path,
        artifact_sha256: ("sha256:" + $sdk_artifact_sha)
      },
      provider_release: (
        if $provider_mode == "image" then
          {
            mode: "image",
            release_ref: $provider_release_ref,
            image_ref: $provider_image_ref,
            image_digest: $provider_image_digest
          }
        else
          {
            mode: "artifact",
            release_ref: $provider_release_ref,
            artifact_path: $provider_artifact_path,
            artifact_sha256: ("sha256:" + $provider_artifact_sha)
          }
        end
      ),
      staging_strict_proof: {
        log_path: $staging_log_path,
        log_sha256: ("sha256:" + $staging_log_sha),
        log_size_bytes: $staging_log_size,
        assertions: $assertions
      },
      boundary_contract_check: {
        command: "./platform/local/bin/verify-aimxs-boundary.sh",
        status: "pass"
      }
    }' > "${output_json}"

  local evidence_sha
  evidence_sha="$(sha256_file "${output_json}")"
  printf '%s  %s\n' "${evidence_sha}" "$(basename "${output_json}")" > "${output_json}.sha256"

  cp "${output_json}" "${latest_json}"
  cp "${output_json}.sha256" "${latest_json}.sha256"

  echo "M10.2 AIMXS private release evidence verification passed."
  echo "  evidence=${output_json}"
  echo "  evidence_sha256=sha256:${evidence_sha}"
  echo "  staging_log=${STAGING_GATE_LOG_PATH}"
  echo "  sdk_tag=${AIMXS_PRIVATE_SDK_RELEASE_TAG}"
  if [ "${provider_mode}" = "image" ]; then
    echo "  provider_release=image:${AIMXS_PRIVATE_PROVIDER_IMAGE_REF}@${AIMXS_PRIVATE_PROVIDER_IMAGE_DIGEST}"
  else
    echo "  provider_release=artifact:${provider_artifact_abs} (sha256:${provider_digest})"
  fi
}

main "$@"
