#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SLOT_FILE="${SLOT_FILE:-${REPO_ROOT}/internal/aimxs/slot.go}"
DOC_FILE="${DOC_FILE:-${REPO_ROOT}/docs/aimxs-plugin-slot.md}"
PUBLICATION_DOC="${PUBLICATION_DOC:-${REPO_ROOT}/docs/runbooks/aimxs-private-sdk-publication.md}"
AIMXS_MANIFEST="${AIMXS_MANIFEST:-${REPO_ROOT}/examples/aimxs/extensionprovider-policy-mtls-bearer.yaml}"
AIMXS_COMPAT_POLICY="${AIMXS_COMPAT_POLICY:-${REPO_ROOT}/platform/upgrade/compatibility-policy-aimxs-decision-api.yaml}"
ALLOWED_LOCAL_IMPORT="github.com/Epydios/Epydios-AgentOps-Desktop/internal/aimxs"

failures=0

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

fail_check() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

pass_check() {
  echo "OK: $1"
}

require_file() {
  local file="$1"
  local label="$2"
  if [ ! -f "${file}" ]; then
    fail_check "${label} not found: ${file}"
    return 1
  fi
  pass_check "${label} present: ${file}"
}

check_slot_contract() {
  require_file "${SLOT_FILE}" "AIMXS slot contract file" || return 0

  if ! rg -q 'type SlotResolver interface' "${SLOT_FILE}"; then
    fail_check "slot contract missing SlotResolver interface"
  fi
  if ! rg -q 'type SlotRegistry interface' "${SLOT_FILE}"; then
    fail_check "slot contract missing SlotRegistry interface"
  fi
  if ! rg -q 'type Registration struct' "${SLOT_FILE}"; then
    fail_check "slot contract missing Registration struct"
  fi
  if ! rg -q 'EndpointAuthMTLSAndBearerTokenRef' "${SLOT_FILE}"; then
    fail_check "slot contract missing MTLSAndBearerTokenSecret auth enum"
  fi
}

check_import_boundary() {
  local import_lines import_path allowed_refs disallowed_refs line
  allowed_refs=0
  disallowed_refs=0

  import_lines="$(rg -n '^[[:space:]]*"[^"]*aimxs[^"]*"' "${REPO_ROOT}" --glob '*.go' || true)"
  if [ -z "${import_lines}" ]; then
    pass_check "no go import paths reference aimxs directly"
    return 0
  fi

  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    import_path="$(printf '%s\n' "${line}" | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*"([^"]+)".*/\1/')"
    if [ -z "${import_path}" ]; then
      continue
    fi
    if [ "${import_path}" = "${ALLOWED_LOCAL_IMPORT}" ]; then
      allowed_refs=$((allowed_refs + 1))
      continue
    fi
    disallowed_refs=$((disallowed_refs + 1))
    fail_check "disallowed aimxs import path '${import_path}' (${line})"
  done <<<"${import_lines}"

  if [ "${disallowed_refs}" -eq 0 ]; then
    pass_check "aimxs imports restricted to local slot boundary (${allowed_refs} allowed refs)"
  fi
}

check_module_boundary() {
  local module_files=()
  [ -f "${REPO_ROOT}/go.mod" ] && module_files+=("${REPO_ROOT}/go.mod")
  [ -f "${REPO_ROOT}/go.sum" ] && module_files+=("${REPO_ROOT}/go.sum")

  if [ "${#module_files[@]}" -eq 0 ]; then
    fail_check "go.mod/go.sum not found for module boundary check"
    return 0
  fi

  if rg -n 'aimxs' "${module_files[@]}" >/dev/null 2>&1; then
    fail_check "module files reference aimxs; AIMXS must stay out of OSS dependency graph"
    return 0
  fi

  pass_check "module graph contains no direct aimxs references"
}

check_manifest_auth_and_https() {
  local url mode provider_id

  require_file "${AIMXS_MANIFEST}" "AIMXS provider example manifest" || return 0

  url="$(awk '/^[[:space:]]*url:[[:space:]]*/ {print $2; exit}' "${AIMXS_MANIFEST}")"
  mode="$(awk '/^[[:space:]]*mode:[[:space:]]*/ {print $2; exit}' "${AIMXS_MANIFEST}")"
  provider_id="$(awk '/^[[:space:]]*providerId:[[:space:]]*/ {print $2; exit}' "${AIMXS_MANIFEST}")"

  if [ -z "${url}" ] || [[ "${url}" != https://* ]]; then
    fail_check "AIMXS endpoint url must be HTTPS (found '${url:-<empty>}')"
  else
    pass_check "AIMXS endpoint url is HTTPS (${url})"
  fi

  case "${mode}" in
    MTLS|MTLSAndBearerTokenSecret)
      pass_check "AIMXS auth mode is secure (${mode})"
      ;;
    "")
      fail_check "AIMXS auth mode missing in example manifest"
      ;;
    *)
      fail_check "AIMXS auth mode must be MTLS or MTLSAndBearerTokenSecret (found ${mode})"
      ;;
  esac

  if [ -z "${provider_id}" ] || [[ "${provider_id}" != aimxs-* ]]; then
    fail_check "AIMXS providerId should be namespaced with 'aimxs-' (found '${provider_id:-<empty>}')"
  else
    pass_check "AIMXS providerId namespace check passed (${provider_id})"
  fi

  if [ "${mode}" = "MTLSAndBearerTokenSecret" ]; then
    if ! rg -q '^[[:space:]]*bearerTokenSecretRef:' "${AIMXS_MANIFEST}"; then
      fail_check "AIMXS manifest missing bearerTokenSecretRef for MTLSAndBearerTokenSecret mode"
    fi
    if ! rg -q '^[[:space:]]*clientTLSSecretRef:' "${AIMXS_MANIFEST}"; then
      fail_check "AIMXS manifest missing clientTLSSecretRef for MTLSAndBearerTokenSecret mode"
    fi
    if ! rg -q '^[[:space:]]*caSecretRef:' "${AIMXS_MANIFEST}"; then
      fail_check "AIMXS manifest missing caSecretRef for MTLSAndBearerTokenSecret mode"
    fi
  fi
}

check_boundary_doc() {
  require_file "${DOC_FILE}" "AIMXS boundary documentation" || return 0

  if ! rg -q 'AIMXS remains private and external to the OSS build graph' "${DOC_FILE}"; then
    fail_check "AIMXS boundary doc missing explicit private/external boundary statement"
  fi
  if ! rg -q 'OSS must not import AIMXS code directly' "${DOC_FILE}"; then
    fail_check "AIMXS boundary doc missing direct-import prohibition"
  fi
  if ! rg -q 'Use HTTPS endpoint URLs' "${DOC_FILE}"; then
    fail_check "AIMXS boundary doc missing HTTPS endpoint requirement"
  fi
  if ! rg -q '^## Conformance and Failure Handling' "${DOC_FILE}"; then
    fail_check "AIMXS boundary doc missing conformance/failure-handling section"
  fi
}

check_publication_doc() {
  require_file "${PUBLICATION_DOC}" "AIMXS private publication runbook" || return 0

  if ! rg -q '^# AIMXS Private SDK Publication' "${PUBLICATION_DOC}"; then
    fail_check "AIMXS publication runbook missing title"
  fi
  if ! rg -q 'verify-aimxs-boundary.sh' "${PUBLICATION_DOC}"; then
    fail_check "AIMXS publication runbook must require OSS boundary verification"
  fi
  if ! rg -q 'First private SDK release tag published' "${PUBLICATION_DOC}"; then
    fail_check "AIMXS publication runbook missing completion evidence checklist"
  fi
}

check_compatibility_policy() {
  require_file "${AIMXS_COMPAT_POLICY}" "AIMXS compatibility policy" || return 0

  if ! rg -q '^component:[[:space:]]*aimxs-decision-api' "${AIMXS_COMPAT_POLICY}"; then
    fail_check "AIMXS compatibility policy missing aimxs-decision-api component marker"
  fi
  if ! rg -q '/v1/decide' "${AIMXS_COMPAT_POLICY}"; then
    fail_check "AIMXS compatibility policy missing /v1/decide endpoint requirement"
  fi
  if ! rg -q '^grant_token_policy:' "${AIMXS_COMPAT_POLICY}"; then
    fail_check "AIMXS compatibility policy missing grant_token_policy section"
  fi
  if ! rg -q 'output\.aimxsGrantToken' "${AIMXS_COMPAT_POLICY}"; then
    fail_check "AIMXS compatibility policy missing output.aimxsGrantToken accepted path"
  fi
  if ! rg -q 'AUTHZ_REQUIRE_POLICY_GRANT' "${AIMXS_COMPAT_POLICY}"; then
    fail_check "AIMXS compatibility policy should reference AUTHZ_REQUIRE_POLICY_GRANT runtime enforcement knob"
  fi
}

main() {
  require_cmd rg
  require_cmd awk
  require_cmd sed

  check_slot_contract
  check_import_boundary
  check_module_boundary
  check_manifest_auth_and_https
  check_boundary_doc
  check_publication_doc
  check_compatibility_policy

  if [ "${failures}" -gt 0 ]; then
    echo "AIMXS boundary verification failed with ${failures} issue(s)." >&2
    exit 1
  fi

  echo "AIMXS boundary verification passed."
  echo "  slot_file=${SLOT_FILE}"
  echo "  doc_file=${DOC_FILE}"
  echo "  publication_doc=${PUBLICATION_DOC}"
  echo "  manifest=${AIMXS_MANIFEST}"
  echo "  compatibility_policy=${AIMXS_COMPAT_POLICY}"
}

main "$@"
