#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-epydios-system}"
MIN_TLS_VALIDITY_DAYS="${MIN_TLS_VALIDITY_DAYS:-30}"
FAIL_ON_NO_MTLS_REFS="${FAIL_ON_NO_MTLS_REFS:-0}"

TMPDIR_LOCAL="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR_LOCAL}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

b64decode_stdin() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

secret_data_b64() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" -o "go-template={{index .data \"${key}\"}}" 2>/dev/null || true
}

read_secret_key_to_file() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local out_file="$4"
  local b64

  b64="$(secret_data_b64 "${namespace}" "${secret_name}" "${key}")"
  if [ -z "${b64}" ]; then
    return 1
  fi

  printf '%s' "${b64}" | b64decode_stdin >"${out_file}"
}

read_secret_key_string() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local b64

  b64="$(secret_data_b64 "${namespace}" "${secret_name}" "${key}")"
  if [ -z "${b64}" ]; then
    return 1
  fi

  printf '%s' "${b64}" | b64decode_stdin
}

days_until_cert_expiry() {
  local cert_file="$1"
  local not_after epoch now

  not_after="$(openssl x509 -enddate -noout -in "${cert_file}" | sed 's/^notAfter=//')"

  if epoch="$(date -u -d "${not_after}" +%s 2>/dev/null)"; then
    :
  elif epoch="$(date -u -j -f "%b %e %T %Y %Z" "${not_after}" +%s 2>/dev/null)"; then
    :
  else
    echo "Unable to parse certificate expiry date: ${not_after}" >&2
    return 1
  fi

  now="$(date -u +%s)"
  echo $(( (epoch - now) / 86400 ))
}

main() {
  require_cmd kubectl
  require_cmd openssl
  require_cmd base64
  require_cmd date

  local providers provider mode bearer_secret bearer_key client_tls_secret ca_secret
  local failures=0
  local mtls_refs=0
  local bearer_refs=0

  providers="$(kubectl -n "${NAMESPACE}" get extensionprovider -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

  if [ -z "${providers}" ]; then
    echo "No ExtensionProvider resources found in namespace ${NAMESPACE}; rotation check skipped."
    exit 0
  fi

  while IFS= read -r provider; do
    [ -n "${provider}" ] || continue

    mode="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.mode}' 2>/dev/null || true)"
    if [ -z "${mode}" ] || [ "${mode}" = "None" ]; then
      continue
    fi

    echo "Checking provider ${provider} auth.mode=${mode}"

    case "${mode}" in
      BearerTokenSecret|MTLSAndBearerTokenSecret)
        bearer_refs=$((bearer_refs + 1))
        bearer_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.name}' 2>/dev/null || true)"
        bearer_key="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.bearerTokenSecretRef.key}' 2>/dev/null || true)"
        if [ -z "${bearer_key}" ]; then
          bearer_key="token"
        fi
        if [ -z "${bearer_secret}" ]; then
          echo "  FAIL: missing bearerTokenSecretRef.name" >&2
          failures=$((failures + 1))
        else
          if ! token_value="$(read_secret_key_string "${NAMESPACE}" "${bearer_secret}" "${bearer_key}" 2>/dev/null)"; then
            echo "  FAIL: missing bearer token secret/key ${NAMESPACE}/${bearer_secret}:${bearer_key}" >&2
            failures=$((failures + 1))
          elif [ -z "${token_value}" ]; then
            echo "  FAIL: empty bearer token ${NAMESPACE}/${bearer_secret}:${bearer_key}" >&2
            failures=$((failures + 1))
          else
            echo "  OK: bearer token secret present (${NAMESPACE}/${bearer_secret}:${bearer_key})"
          fi
        fi
        ;;
    esac

    case "${mode}" in
      MTLS|MTLSAndBearerTokenSecret)
        mtls_refs=$((mtls_refs + 1))
        client_tls_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.clientTLSSecretRef.name}' 2>/dev/null || true)"
        ca_secret="$(kubectl -n "${NAMESPACE}" get extensionprovider "${provider}" -o jsonpath='{.spec.auth.caSecretRef.name}' 2>/dev/null || true)"

        if [ -z "${client_tls_secret}" ]; then
          echo "  FAIL: missing clientTLSSecretRef.name" >&2
          failures=$((failures + 1))
        else
          local cert_file key_file days_left
          cert_file="${TMPDIR_LOCAL}/${provider}-client.crt"
          key_file="${TMPDIR_LOCAL}/${provider}-client.key"

          if ! read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.crt" "${cert_file}"; then
            echo "  FAIL: missing client cert ${NAMESPACE}/${client_tls_secret}:tls.crt" >&2
            failures=$((failures + 1))
          fi
          if ! read_secret_key_to_file "${NAMESPACE}" "${client_tls_secret}" "tls.key" "${key_file}"; then
            echo "  FAIL: missing client key ${NAMESPACE}/${client_tls_secret}:tls.key" >&2
            failures=$((failures + 1))
          fi

          if [ -f "${cert_file}" ]; then
            days_left="$(days_until_cert_expiry "${cert_file}" || true)"
            if [ -z "${days_left}" ]; then
              echo "  FAIL: could not parse client certificate expiry for ${NAMESPACE}/${client_tls_secret}" >&2
              failures=$((failures + 1))
            elif [ "${days_left}" -lt "${MIN_TLS_VALIDITY_DAYS}" ]; then
              echo "  FAIL: client certificate expires in ${days_left} day(s), threshold=${MIN_TLS_VALIDITY_DAYS}" >&2
              failures=$((failures + 1))
            else
              echo "  OK: client certificate validity ${days_left} day(s)"
            fi
          fi
        fi

        if [ -n "${ca_secret}" ]; then
          local ca_file ca_days
          ca_file="${TMPDIR_LOCAL}/${provider}-ca.crt"
          if ! read_secret_key_to_file "${NAMESPACE}" "${ca_secret}" "ca.crt" "${ca_file}"; then
            read_secret_key_to_file "${NAMESPACE}" "${ca_secret}" "tls.crt" "${ca_file}" || true
          fi
          if [ -f "${ca_file}" ]; then
            ca_days="$(days_until_cert_expiry "${ca_file}" || true)"
            if [ -z "${ca_days}" ]; then
              echo "  FAIL: could not parse CA certificate expiry for ${NAMESPACE}/${ca_secret}" >&2
              failures=$((failures + 1))
            elif [ "${ca_days}" -lt "${MIN_TLS_VALIDITY_DAYS}" ]; then
              echo "  FAIL: CA certificate expires in ${ca_days} day(s), threshold=${MIN_TLS_VALIDITY_DAYS}" >&2
              failures=$((failures + 1))
            else
              echo "  OK: CA certificate validity ${ca_days} day(s)"
            fi
          else
            echo "  FAIL: missing ca.crt/tls.crt in ${NAMESPACE}/${ca_secret}" >&2
            failures=$((failures + 1))
          fi
        fi
        ;;
    esac
  done <<<"${providers}"

  if [ "${mtls_refs}" -eq 0 ]; then
    if [ "${FAIL_ON_NO_MTLS_REFS}" = "1" ]; then
      echo "FAIL: no MTLS/MTLSAndBearerTokenSecret provider refs found in ${NAMESPACE}" >&2
      failures=$((failures + 1))
    else
      echo "Note: no MTLS provider refs found; skipped TLS expiry checks."
    fi
  fi

  if [ "${failures}" -gt 0 ]; then
    echo "Secret/cert rotation check failed with ${failures} issue(s)." >&2
    exit 1
  fi

  echo "Secret/cert rotation check passed (mtls_refs=${mtls_refs}, bearer_refs=${bearer_refs}, threshold_days=${MIN_TLS_VALIDITY_DAYS})."
}

main "$@"
