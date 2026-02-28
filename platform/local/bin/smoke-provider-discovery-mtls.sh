#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"
TOKEN_VALUE="${TOKEN_VALUE:-epydios-local-mtls-token}"

TMPDIR_LOCAL="$(mktemp -d)"

cleanup() {
  if [ "${KEEP_RESOURCES}" != "1" ]; then
    kubectl delete -k "${REPO_ROOT}/platform/tests/provider-discovery-mtls" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "${NAMESPACE}" delete secret \
      epydios-controller-mtls-client \
      epydios-provider-ca \
      mtls-provider-server-tls \
      mtls-bearer-client-token \
      mtls-bearer-provider-token \
      --ignore-not-found >/dev/null 2>&1 || true
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

generate_pki() {
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=epydios-local-mtls-ca" \
    -keyout "${TMPDIR_LOCAL}/ca.key" \
    -out "${TMPDIR_LOCAL}/ca.crt" >/dev/null 2>&1

  cat >"${TMPDIR_LOCAL}/server.ext" <<'EOF'
subjectAltName=DNS:mtls-only-provider.epydios-system.svc.cluster.local,DNS:mtls-only-provider.epydios-system.svc,DNS:mtls-only-provider,DNS:mtls-bearer-provider.epydios-system.svc.cluster.local,DNS:mtls-bearer-provider.epydios-system.svc,DNS:mtls-bearer-provider,DNS:phase4-mtls-policy-provider.epydios-system.svc.cluster.local,DNS:phase4-mtls-policy-provider.epydios-system.svc,DNS:phase4-mtls-policy-provider,DNS:phase4-mtls-bearer-evidence-provider.epydios-system.svc.cluster.local,DNS:phase4-mtls-bearer-evidence-provider.epydios-system.svc,DNS:phase4-mtls-bearer-evidence-provider
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=epydios-mtls-provider" \
    -keyout "${TMPDIR_LOCAL}/server.key" \
    -out "${TMPDIR_LOCAL}/server.csr" >/dev/null 2>&1
  openssl x509 -req \
    -in "${TMPDIR_LOCAL}/server.csr" \
    -CA "${TMPDIR_LOCAL}/ca.crt" \
    -CAkey "${TMPDIR_LOCAL}/ca.key" \
    -CAcreateserial \
    -out "${TMPDIR_LOCAL}/server.crt" \
    -days 825 \
    -sha256 \
    -extfile "${TMPDIR_LOCAL}/server.ext" >/dev/null 2>&1

  cat >"${TMPDIR_LOCAL}/client.ext" <<'EOF'
extendedKeyUsage=clientAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=extension-provider-registry-controller" \
    -keyout "${TMPDIR_LOCAL}/client.key" \
    -out "${TMPDIR_LOCAL}/client.csr" >/dev/null 2>&1
  openssl x509 -req \
    -in "${TMPDIR_LOCAL}/client.csr" \
    -CA "${TMPDIR_LOCAL}/ca.crt" \
    -CAkey "${TMPDIR_LOCAL}/ca.key" \
    -CAcreateserial \
    -out "${TMPDIR_LOCAL}/client.crt" \
    -days 825 \
    -sha256 \
    -extfile "${TMPDIR_LOCAL}/client.ext" >/dev/null 2>&1
}

apply_secrets() {
  kubectl -n "${NAMESPACE}" create secret tls epydios-controller-mtls-client \
    --cert="${TMPDIR_LOCAL}/client.crt" \
    --key="${TMPDIR_LOCAL}/client.key" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic epydios-provider-ca \
    --from-file=ca.crt="${TMPDIR_LOCAL}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic mtls-provider-server-tls \
    --from-file=tls.crt="${TMPDIR_LOCAL}/server.crt" \
    --from-file=tls.key="${TMPDIR_LOCAL}/server.key" \
    --from-file=ca.crt="${TMPDIR_LOCAL}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic mtls-bearer-client-token \
    --from-literal=token="${TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic mtls-bearer-provider-token \
    --from-literal=token="${TOKEN_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

wait_for_deployment() {
  local name="$1"
  kubectl -n "${NAMESPACE}" wait --for=condition=Available "deployment/${name}" --timeout=6m
}

wait_for_provider_ready() {
  local provider_name="$1"
  local expected_provider_id="$2"
  local start
  start="$(date +%s)"

  while true; do
    local statuses ready probed provider_id
    statuses="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider_name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{";"}{end}' 2>/dev/null || true
    )"
    ready="$(printf '%s' "${statuses}" | tr ';' '\n' | awk -F= '$1=="Ready"{print $2; exit}')"
    probed="$(printf '%s' "${statuses}" | tr ';' '\n' | awk -F= '$1=="Probed"{print $2; exit}')"
    provider_id="$(
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider_name}" \
        -o jsonpath='{.status.resolved.providerId}' 2>/dev/null || true
    )"

    if [ "${ready}" = "True" ] && [ "${probed}" = "True" ] && [ "${provider_id}" = "${expected_provider_id}" ]; then
      echo "mTLS case passed: ${provider_name} (providerId=${provider_id})"
      return 0
    fi

    if [ $(( $(date +%s) - start )) -ge "${TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for mTLS provider readiness on ${provider_name}" >&2
      echo "statuses=${statuses}" >&2
      echo "provider_id=${provider_id}" >&2
      kubectl -n "${NAMESPACE}" get extensionprovider "${provider_name}" -o yaml >&2 || true
      return 1
    fi

    sleep 2
  done
}

main() {
  require_cmd kubectl
  require_cmd openssl

  generate_pki
  apply_secrets

  kubectl apply -k "${REPO_ROOT}/platform/tests/provider-discovery-mtls"

  wait_for_deployment mtls-only-provider
  wait_for_deployment mtls-bearer-provider

  wait_for_provider_ready mtls-only-profile mtls-only-profile-provider
  wait_for_provider_ready mtls-bearer-evidence mtls-bearer-evidence-provider

  echo "mTLS provider-discovery smoke passed (MTLS + MTLSAndBearerTokenSecret)."
}

main "$@"
