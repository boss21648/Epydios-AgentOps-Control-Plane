#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PROFILE="${PROFILE:-}"
PROFILE_FILE="${PROFILE_FILE:-}"

usage() {
  cat <<'EOF'
Usage:
  PROFILE=<name> ./platform/ci/bin/run-gate-profile.sh
  PROFILE_FILE=<path> ./platform/ci/bin/run-gate-profile.sh
  ./platform/ci/bin/run-gate-profile.sh <name>

Profiles are loaded from platform/ci/profiles/<name>.env unless PROFILE_FILE is set.
EOF
}

resolve_profile_file() {
  if [ -n "${PROFILE_FILE}" ]; then
    echo "${PROFILE_FILE}"
    return 0
  fi

  if [ -z "${PROFILE}" ]; then
    return 1
  fi

  if [ -f "${PROFILE}" ]; then
    echo "${PROFILE}"
    return 0
  fi

  echo "${REPO_ROOT}/platform/ci/profiles/${PROFILE}.env"
}

main() {
  if [ $# -gt 1 ]; then
    usage >&2
    exit 1
  fi

  if [ $# -eq 1 ] && [ -z "${PROFILE}" ] && [ -z "${PROFILE_FILE}" ]; then
    PROFILE="$1"
  fi

  local resolved
  resolved="$(resolve_profile_file || true)"
  if [ -z "${resolved}" ]; then
    usage >&2
    exit 1
  fi

  if [ ! -f "${resolved}" ]; then
    echo "Profile file not found: ${resolved}" >&2
    exit 1
  fi

  echo "Loading gate profile: ${resolved}"
  set -a
  # shellcheck disable=SC1090
  . "${resolved}"
  set +a

  "${SCRIPT_DIR}/pr-kind-phase03-gate.sh"
}

main "$@"
