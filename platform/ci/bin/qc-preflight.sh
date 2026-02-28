#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd go
  require_cmd bash
  require_cmd kubectl
  require_cmd find
  require_cmd sort

  echo "QC: go test ./..."
  (cd "${REPO_ROOT}" && go test ./...)

  echo "QC: shell syntax validation (platform/**/*.sh)"
  while IFS= read -r script; do
    bash -n "${script}"
  done < <(find "${REPO_ROOT}/platform" -type f -name "*.sh" | sort)

  echo "QC: render all kustomizations"
  while IFS= read -r kustomization; do
    kubectl kustomize "$(dirname "${kustomization}")" >/dev/null
  done < <(find "${REPO_ROOT}/platform" -type f -name "kustomization.yaml" | sort)

  echo "QC preflight passed."
}

main "$@"
