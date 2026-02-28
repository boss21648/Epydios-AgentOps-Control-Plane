#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-epydios-system}"
APPLY_SIGNED_IMAGE_POLICY="${APPLY_SIGNED_IMAGE_POLICY:-auto}" # auto|1|0
REQUIRE_SIGNED_IMAGE_POLICY="${REQUIRE_SIGNED_IMAGE_POLICY:-0}"
CLEANUP_POLICIES="${CLEANUP_POLICIES:-1}"

# Deliberately tag-based for denial assertion.
MUTABLE_IMAGE="${MUTABLE_IMAGE:-openpolicyagent/opa:0.67.1}"
# Pinned digest to assert allow-path under immutable policy.
IMMUTABLE_IMAGE="${IMMUTABLE_IMAGE:-openpolicyagent/opa@sha256:15151b408ff6477e5f6b675e491cab60776be84be4fcbc19ca2d2024cec789bf}"
# Deliberately digest-pinned but expected unsigned for Kyverno keyless policy.
UNSIGNED_IMAGE="${UNSIGNED_IMAGE:-ghcr.io/epydios/epydios-control-plane-runtime@sha256:babbddab65e14b247cc14a902ecb71430bb9b4161e8d925cbe50ce3417953078}"

SIGNED_POLICY_APPLIED="0"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ "${CLEANUP_POLICIES}" != "1" ]; then
    return 0
  fi

  kubectl delete -k "${REPO_ROOT}/platform/hardening/admission" --ignore-not-found >/dev/null 2>&1 || true
  if [ "${SIGNED_POLICY_APPLIED}" = "1" ]; then
    kubectl delete -k "${REPO_ROOT}/platform/hardening/admission-kyverno" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

expect_denied() {
  local file="$1"
  local expected="$2"
  local retries="${3:-1}"
  local sleep_seconds="${4:-1}"
  local output
  local rc=0
  local attempt=1

  while true; do
    set +e
    output="$(kubectl -n "${NAMESPACE}" apply --dry-run=server -f "${file}" 2>&1)"
    rc=$?
    set -e

    if [ "${rc}" -ne 0 ] && grep -qi "${expected}" <<<"${output}"; then
      return 0
    fi

    if [ "${attempt}" -ge "${retries}" ]; then
      if [ "${rc}" -eq 0 ]; then
        echo "Expected admission denial for ${file}, but request was allowed." >&2
      else
        echo "Admission denial did not include expected marker '${expected}'." >&2
      fi
      echo "${output}" >&2
      exit 1
    fi

    attempt=$((attempt + 1))
    sleep "${sleep_seconds}"
  done
}

expect_allowed() {
  local file="$1"
  kubectl -n "${NAMESPACE}" apply --dry-run=server -f "${file}" >/dev/null
}

main() {
  require_cmd kubectl

  trap cleanup EXIT

  local tmpdir
  tmpdir="$(mktemp -d)"

  cat >"${tmpdir}/mutable-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: admission-mutable-deny
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: ${MUTABLE_IMAGE}
      command: ["sh", "-c", "sleep 5"]
EOF

  cat >"${tmpdir}/immutable-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: admission-immutable-allow
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: ${IMMUTABLE_IMAGE}
      command: ["sh", "-c", "sleep 5"]
EOF

  cat >"${tmpdir}/unsigned-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: admission-unsigned-deny
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: ${UNSIGNED_IMAGE}
      command: ["sh", "-c", "sleep 5"]
EOF

  echo "Applying immutable image admission policy..."
  kubectl apply -k "${REPO_ROOT}/platform/hardening/admission" >/dev/null
  kubectl label namespace "${NAMESPACE}" epydios.ai/admission-enforced=true --overwrite >/dev/null

  echo "Waiting for immutable policy to become active..."
  expect_denied "${tmpdir}/mutable-pod.yaml" "immutable digest" 20 1

  echo "Asserting mutable image denial..."
  expect_denied "${tmpdir}/mutable-pod.yaml" "immutable digest"

  echo "Asserting immutable digest allow-path..."
  expect_allowed "${tmpdir}/immutable-pod.yaml"

  local kyverno_present="0"
  if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    kyverno_present="1"
  fi

  local apply_signed="0"
  case "${APPLY_SIGNED_IMAGE_POLICY}" in
    1) apply_signed="1" ;;
    0) apply_signed="0" ;;
    auto)
      if [ "${kyverno_present}" = "1" ]; then
        apply_signed="1"
      fi
      ;;
    *)
      echo "Unsupported APPLY_SIGNED_IMAGE_POLICY=${APPLY_SIGNED_IMAGE_POLICY} (expected auto|1|0)" >&2
      exit 1
      ;;
  esac

  if [ "${apply_signed}" = "1" ]; then
    if [ "${kyverno_present}" != "1" ]; then
      echo "Kyverno CRD not found, but signed-image policy application was requested." >&2
      exit 1
    fi
    echo "Applying Kyverno signed-image policy..."
    kubectl apply -k "${REPO_ROOT}/platform/hardening/admission-kyverno" >/dev/null
    SIGNED_POLICY_APPLIED="1"

    echo "Asserting unsigned Epydios image denial..."
    # Denial wording varies (signature mismatch vs registry verification failure),
    # but the Kyverno policy name is stable.
    expect_denied "${tmpdir}/unsigned-pod.yaml" "epydios-verify-signed-images" 20 1
  elif [ "${REQUIRE_SIGNED_IMAGE_POLICY}" = "1" ]; then
    echo "Signed-image admission policy is required, but Kyverno policy was not applied." >&2
    echo "Set APPLY_SIGNED_IMAGE_POLICY=1 and ensure Kyverno is installed." >&2
    exit 1
  else
    echo "Skipping signed-image admission check (Kyverno unavailable or policy disabled)."
  fi

  echo "Admission enforcement verification passed."
}

main "$@"
