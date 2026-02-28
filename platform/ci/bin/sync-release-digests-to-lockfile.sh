#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

DIGEST_MANIFEST="${DIGEST_MANIFEST:-${REPO_ROOT}/dist/release-image-digests.json}"
LOCKFILE="${LOCKFILE:-${REPO_ROOT}/provenance/images.lock.yaml}"
DRY_RUN="${DRY_RUN:-0}"
REQUIRE_PUSHED="${REQUIRE_PUSHED:-1}"
UPDATE_STATUS="${UPDATE_STATUS:-release-synced}"

tmp_updates="$(mktemp)"
tmp_out="$(mktemp)"

cleanup() {
  rm -f "${tmp_updates}" "${tmp_out}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

validate_inputs() {
  [ -f "${DIGEST_MANIFEST}" ] || {
    echo "Digest manifest not found: ${DIGEST_MANIFEST}" >&2
    exit 1
  }
  [ -f "${LOCKFILE}" ] || {
    echo "Lockfile not found: ${LOCKFILE}" >&2
    exit 1
  }

  jq -e 'type == "array"' "${DIGEST_MANIFEST}" >/dev/null || {
    echo "Digest manifest must be a JSON array: ${DIGEST_MANIFEST}" >&2
    exit 1
  }
}

collect_updates() {
  jq -r '.[] | [.component, .lock_tag, .digest, .pushed] | @tsv' "${DIGEST_MANIFEST}" \
    | while IFS=$'\t' read -r component lock_tag digest pushed; do
        [ -n "${component}" ] || {
          echo "Digest manifest entry missing component" >&2
          exit 2
        }
        [ -n "${lock_tag}" ] || {
          echo "Digest manifest entry missing lock_tag for component=${component}" >&2
          exit 2
        }
        if ! [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
          echo "Digest manifest entry has invalid digest for component=${component}: ${digest}" >&2
          exit 2
        fi
        if [ "${REQUIRE_PUSHED}" = "1" ] && [ "${pushed}" != "true" ]; then
          echo "Digest manifest entry is not pushed=true for component=${component}" >&2
          exit 2
        fi
        printf '%s|%s|%s\n' "${component}" "${lock_tag}" "${digest}"
      done >"${tmp_updates}"

  if [ ! -s "${tmp_updates}" ]; then
    echo "No update entries found in ${DIGEST_MANIFEST}" >&2
    exit 1
  fi
}

apply_updates() {
  awk -F'|' -v updates_file="${tmp_updates}" -v update_status="${UPDATE_STATUS}" '
    function trim(v) {
      gsub(/^ +| +$/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      return v
    }
    BEGIN {
      while ((getline line < updates_file) > 0) {
        split(line, parts, "|")
        component = parts[1]
        lock_tag[component] = parts[2]
        digest[component] = parts[3]
        expected[component] = 1
      }
      close(updates_file)
      current = ""
    }
    /^  - component: / {
      current = $0
      sub(/^  - component: /, "", current)
      current = trim(current)
    }
    {
      if (current in expected && $0 ~ /^    tag: /) {
        $0 = "    tag: \"" lock_tag[current] "\""
        touched[current] = 1
      } else if (current in expected && $0 ~ /^    digest: /) {
        $0 = "    digest: " digest[current]
        touched[current] = 1
      } else if (current in expected && update_status != "" && $0 ~ /^    status: /) {
        $0 = "    status: " update_status
        touched[current] = 1
      }
      print
    }
    END {
      missing = 0
      for (c in expected) {
        if (!(c in touched)) {
          print "Missing component in lockfile for update: " c > "/dev/stderr"
          missing = 1
        }
      }
      if (missing != 0) {
        exit 3
      }
    }
  ' "${LOCKFILE}" >"${tmp_out}"
}

print_summary() {
  echo "Release digest sync summary:"
  awk -F'|' '{printf "  - %s: tag=%s digest=%s\n", $1, $2, $3}' "${tmp_updates}"
  echo "  lockfile=${LOCKFILE}"
}

main() {
  require_cmd jq
  require_cmd awk

  validate_inputs
  collect_updates
  apply_updates

  if [ "${DRY_RUN}" = "1" ]; then
    echo "DRY_RUN=1 -> not writing ${LOCKFILE}"
  else
    mv "${tmp_out}" "${LOCKFILE}"
  fi

  print_summary
}

main "$@"
