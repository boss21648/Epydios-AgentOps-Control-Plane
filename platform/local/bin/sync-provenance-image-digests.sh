#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

LOCKFILE="${LOCKFILE:-${REPO_ROOT}/provenance/images.lock.yaml}"
DRY_RUN="${DRY_RUN:-0}"
USE_DOCKER_CACHE="${USE_DOCKER_CACHE:-1}"
ALLOW_DOCKER_PULL="${ALLOW_DOCKER_PULL:-0}"

tmp_runtime_images="$(mktemp)"
tmp_runtime_map="$(mktemp)"
tmp_lock_entries="$(mktemp)"
tmp_updates="$(mktemp)"
tmp_out="$(mktemp)"

cleanup() {
  rm -f "${tmp_runtime_images}" "${tmp_runtime_map}" "${tmp_lock_entries}" "${tmp_updates}" "${tmp_out}"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

trim_quotes() {
  local in="$1"
  in="${in%\"}"
  in="${in#\"}"
  in="${in%\'}"
  in="${in#\'}"
  printf '%s' "${in}"
}

normalize_repo_tag() {
  local image="$1"
  local tag="$2"
  image="$(trim_quotes "${image}")"
  tag="$(trim_quotes "${tag}")"
  image="${image#docker.io/}"
  printf '%s:%s' "${image}" "${tag}"
}

extract_runtime_key() {
  local image_ref="$1"
  image_ref="${image_ref%%@*}"
  image_ref="${image_ref#docker.io/}"

  local repo="${image_ref%:*}"
  local tag="${image_ref##*:}"
  if [ "${repo}" = "${tag}" ]; then
    tag="latest"
  fi
  printf '%s:%s' "${repo}" "${tag}"
}

extract_digest() {
  local image_id="$1"
  image_id="${image_id#docker-pullable://}"

  if [[ "${image_id}" == *@sha256:* ]]; then
    printf 'sha256:%s' "${image_id##*@sha256:}"
    return 0
  fi
  if [[ "${image_id}" =~ sha256:[0-9a-f]{64} ]]; then
    printf '%s' "${BASH_REMATCH[0]}"
    return 0
  fi
  return 1
}

is_placeholder_digest() {
  local digest
  digest="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${digest}" || "${digest}" == "sha256:tbd" || "${digest}" == *"tbd"* || "${digest}" == "n/a" ]]
}

is_placeholder_value() {
  local v
  v="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${v}" || "${v}" == "tbd" || "${v}" == *"tbd"* || "${v}" == "n/a" ]]
}

resolve_digest_via_docker() {
  local image="$1"
  local tag="$2"
  local ref="${image}:${tag}"
  local repo_digest=""

  if [ "${USE_DOCKER_CACHE}" = "1" ] || [ "${ALLOW_DOCKER_PULL}" = "1" ]; then
    repo_digest="$(docker image inspect "${ref}" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  fi

  if [ -z "${repo_digest}" ] && [ "${ALLOW_DOCKER_PULL}" = "1" ]; then
    echo "Pulling ${ref} to resolve digest..." >&2
    if docker pull "${ref}" >/dev/null 2>&1; then
      repo_digest="$(docker image inspect "${ref}" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    fi
  fi

  if [[ "${repo_digest}" == *@sha256:* ]]; then
    printf 'sha256:%s' "${repo_digest##*@sha256:}"
    return 0
  fi
  return 1
}

is_real_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]
}

collect_runtime_images() {
  kubectl get pods -A \
    -o jsonpath='{range .items[*]}{range .status.initContainerStatuses[*]}{.image}{"|"}{.imageID}{"\n"}{end}{range .status.containerStatuses[*]}{.image}{"|"}{.imageID}{"\n"}{end}{end}' \
    >"${tmp_runtime_images}"
}

extract_lock_entries() {
  awk '
    function trim(v) {
      gsub(/^ +| +$/, "", v)
      gsub(/^"/, "", v); gsub(/"$/, "", v)
      gsub(/^'\''/, "", v); gsub(/'\''$/, "", v)
      return v
    }
    function flush() {
      if (component != "") {
        print component "|" image "|" tag "|" digest "|" status "|" required
      }
      component = image = tag = digest = status = required = ""
    }
    BEGIN {
      in_images = 0
    }
    $0 == "images:" {
      in_images = 1
      next
    }
    in_images && /^[a-zA-Z0-9_]+:/ {
      flush()
      in_images = 0
      next
    }
    !in_images {
      next
    }
    /^  - component:/ {
      flush()
      component = trim(substr($0, index($0, ":") + 1))
      next
    }
    /^    image:/ {
      image = trim(substr($0, index($0, ":") + 1))
      next
    }
    /^    tag:/ {
      tag = trim(substr($0, index($0, ":") + 1))
      next
    }
    /^    digest:/ {
      digest = trim(substr($0, index($0, ":") + 1))
      next
    }
    /^    required:/ {
      required = trim(substr($0, index($0, ":") + 1))
      next
    }
    /^    status:/ {
      status = trim(substr($0, index($0, ":") + 1))
      next
    }
    END {
      flush()
    }
  ' "${LOCKFILE}" >"${tmp_lock_entries}"
}

apply_updates() {
  awk -F'|' '
    NR == FNR {
      updates[$1] = $2
      next
    }
    {
      if ($0 ~ /^  - component: /) {
        current = $0
        sub(/^  - component: /, "", current)
        gsub(/^"/, "", current)
        gsub(/"$/, "", current)
      }
      if (current != "" && (current in updates) && $0 ~ /^    digest: /) {
        $0 = "    digest: " updates[current]
      }
      print
    }
  ' "${tmp_updates}" "${LOCKFILE}" >"${tmp_out}"

  if [ "${DRY_RUN}" = "1" ]; then
    echo "DRY_RUN=1 -> not writing ${LOCKFILE}"
    return 0
  fi

  mv "${tmp_out}" "${LOCKFILE}"
}

main() {
  require_cmd kubectl
  require_cmd awk
  if [ "${USE_DOCKER_CACHE}" = "1" ] || [ "${ALLOW_DOCKER_PULL}" = "1" ]; then
    require_cmd docker
  fi

  collect_runtime_images

  while IFS='|' read -r image_ref image_id; do
    [ -n "${image_ref}" ] || continue
    [ -n "${image_id}" ] || continue

    local_key="$(extract_runtime_key "${image_ref}")"
    if digest="$(extract_digest "${image_id}")"; then
      if ! awk -F'|' -v k="${local_key}" '$1 == k { found = 1; exit } END { exit(found ? 0 : 1) }' "${tmp_runtime_map}" 2>/dev/null; then
        echo "${local_key}|${digest}" >>"${tmp_runtime_map}"
      fi
    fi
  done <"${tmp_runtime_images}"

  extract_lock_entries

  local updates_count=0
  local unresolved_required=0

  while IFS='|' read -r component image tag digest status required; do
    [ -n "${component}" ] || continue
    status_lc="$(echo "${status}" | tr '[:upper:]' '[:lower:]')"
    required_lc="$(echo "${required}" | tr '[:upper:]' '[:lower:]')"

    key="$(normalize_repo_tag "${image}" "${tag}")"
    found_digest=""
    if [ "${status_lc}" != "deferred" ] && ! is_placeholder_value "${image}" && ! is_placeholder_value "${tag}"; then
      found_digest="$(awk -F'|' -v k="${key}" '$1 == k { print $2; exit }' "${tmp_runtime_map}")"
      if [ -z "${found_digest}" ] && ( [ "${USE_DOCKER_CACHE}" = "1" ] || [ "${ALLOW_DOCKER_PULL}" = "1" ] ); then
        found_digest="$(resolve_digest_via_docker "${image}" "${tag}" || true)"
      fi
    fi

    if is_placeholder_digest "${digest}" && is_real_digest "${found_digest}" && [ "${status_lc}" != "deferred" ]; then
      echo "${component}|${found_digest}" >>"${tmp_updates}"
      updates_count=$((updates_count + 1))
      continue
    fi

    if is_placeholder_digest "${digest}" && [ "${required_lc}" = "true" ] && [ "${status_lc}" != "deferred" ] && [ "${status_lc}" != "local-only" ]; then
      unresolved_required=$((unresolved_required + 1))
    fi
  done <"${tmp_lock_entries}"

  if [ -s "${tmp_updates}" ]; then
    apply_updates
  fi

  echo "Digest sync complete."
  echo "  updated_entries=${updates_count}"
  echo "  unresolved_required_placeholders=${unresolved_required}"

  if [ -s "${tmp_updates}" ]; then
    echo "  updated_components:"
    awk -F'|' '{printf "    - %s -> %s\n", $1, $2}' "${tmp_updates}"
  fi
}

main "$@"
