#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

NAMESPACE="${NAMESPACE:-kserve-smoke}"
ISVC_NAME="${ISVC_NAME:-python-smoke}"
MODEL_NAME="${MODEL_NAME:-python-smoke}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-360}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"

PORT_FORWARD_PID=""
LAST_ERROR=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

stop_port_forward() {
  if [ -z "${PORT_FORWARD_PID}" ]; then
    return 0
  fi
  kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  PORT_FORWARD_PID=""
}

cleanup() {
  stop_port_forward
  if [ "${KEEP_RESOURCES}" = "1" ]; then
    return 0
  fi
  kubectl delete -k "${REPO_ROOT}/platform/tests/kserve-smoke" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

dump_diagnostics() {
  echo "=== KServe smoke diagnostics (${NAMESPACE}/${ISVC_NAME}) ===" >&2
  kubectl -n "${NAMESPACE}" get inferenceservice "${ISVC_NAME}" -o yaml >&2 || true
  kubectl -n "${NAMESPACE}" get deploy,svc,pods,ingress >&2 || true
  kubectl -n "${NAMESPACE}" logs "deployment/${ISVC_NAME}-predictor" -c kserve-container --tail=200 >&2 || true
}

wait_for_isvc_ready() {
  if ! kubectl -n "${NAMESPACE}" wait \
    --for=condition=Ready \
    "inferenceservice/${ISVC_NAME}" \
    --timeout="${TIMEOUT_SECONDS}s"; then
    echo "Timed out waiting for InferenceService readiness: ${NAMESPACE}/${ISVC_NAME}" >&2
    dump_diagnostics
    return 1
  fi
}

predictor_service_name() {
  local name
  for name in "${ISVC_NAME}-predictor" "${ISVC_NAME}-predictor-default"; do
    if kubectl -n "${NAMESPACE}" get svc "${name}" >/dev/null 2>&1; then
      printf '%s' "${name}"
      return 0
    fi
  done
  return 1
}

start_port_forward() {
  local service_name="$1"
  local service_port
  service_port="$(kubectl -n "${NAMESPACE}" get svc "${service_name}" -o jsonpath='{.spec.ports[0].port}')"
  kubectl -n "${NAMESPACE}" port-forward "svc/${service_name}" "${LOCAL_PORT}:${service_port}" >/tmp/epydios-kserve-smoke-port-forward.log 2>&1 &
  PORT_FORWARD_PID="$!"

  local i
  for i in $(seq 1 30); do
    if curl -sS --max-time 1 "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  LAST_ERROR="timed out waiting for local port-forward on 127.0.0.1:${LOCAL_PORT}"
  return 1
}

try_predict_path() {
  local path="$1"
  local body_file code body
  body_file="$(mktemp)"

  code="$(
    curl -sS -o "${body_file}" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data @"${REPO_ROOT}/platform/tests/kserve-smoke/predict-request.json" \
      "http://127.0.0.1:${LOCAL_PORT}${path}" 2>/dev/null || true
  )"
  body="$(cat "${body_file}")"
  rm -f "${body_file}"

  if [ "${code}" = "200" ] && printf '%s' "${body}" | grep -q '"predictions"'; then
    echo "KServe functional smoke response (${path}): ${body}"
    return 0
  fi

  LAST_ERROR="path=${path} status=${code} body=${body}"
  return 1
}

run_inference_check() {
  local service_name
  service_name="$(predictor_service_name)" || {
    LAST_ERROR="predictor service not found for ${ISVC_NAME}"
    return 1
  }

  start_port_forward "${service_name}" || return 1

  local path
  for path in \
    "/v1/models/${MODEL_NAME}:predict" \
    "/v1/models/${ISVC_NAME}:predict" \
    "/v1/models/model:predict"; do
    if try_predict_path "${path}"; then
      stop_port_forward
      return 0
    fi
  done

  stop_port_forward
  return 1
}

main() {
  require_cmd kubectl
  require_cmd curl

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -k "${REPO_ROOT}/platform/tests/kserve-smoke"

  wait_for_isvc_ready
  if ! run_inference_check; then
    echo "Inference request failed: ${LAST_ERROR}" >&2
    dump_diagnostics
    return 1
  fi

  echo "KServe functional smoke passed (${NAMESPACE}/${ISVC_NAME})."
}

main "$@"
