#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TMP_FILE=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ -n "${TMP_FILE}" ]; then
    rm -f "${TMP_FILE}"
  fi
}

main() {
  require_cmd rg

  local -a targets=(
    "${REPO_ROOT}/platform/overlays/production"
    "${REPO_ROOT}/platform/data/cnpg-prod-cluster"
  )
  local -a patterns=(
    'replace-with-[[:alnum:]_.-]+'
    '(^|[^[:alnum:]_])(placeholder|changeme|tbd)([^[:alnum:]_]|$)'
    '(^|[^[:alnum:]_])example\.com([^[:alnum:]_]|$)'
  )

  TMP_FILE="$(mktemp)"
  trap cleanup EXIT

  local target
  for target in "${targets[@]}"; do
    if [ ! -d "${target}" ]; then
      continue
    fi
    rg \
      --line-number \
      --no-heading \
      --color=never \
      --ignore-case \
      -g '*.yaml' \
      -e "${patterns[0]}" \
      -e "${patterns[1]}" \
      -e "${patterns[2]}" \
      "${target}" >>"${TMP_FILE}" || true
  done

  if [ -s "${TMP_FILE}" ]; then
    echo "Production placeholder check failed. Resolve placeholder values in production manifests:" >&2
    sort -u "${TMP_FILE}" >&2
    exit 1
  fi

  echo "Production placeholder check passed."
}

main "$@"
