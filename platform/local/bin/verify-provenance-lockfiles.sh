#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

STRICT="${STRICT:-0}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd go

  if [ "${STRICT}" = "1" ]; then
    (cd "${REPO_ROOT}" && go run ./cmd/provenance-lock-check -strict)
  else
    (cd "${REPO_ROOT}" && go run ./cmd/provenance-lock-check)
  fi
}

main "$@"
