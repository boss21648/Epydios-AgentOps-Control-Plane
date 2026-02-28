#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK_PARENT="$(cd "${REPO_ROOT}/.." && pwd)"

EXTERNAL_SECRETS_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-2.0.1}"
OTEL_OPERATOR_CHART_VERSION="${OTEL_OPERATOR_CHART_VERSION:-0.106.0}"
FLUENT_BIT_CHART_VERSION="${FLUENT_BIT_CHART_VERSION:-0.55.0}"
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.19.0}"

RUN_GATEWAY_API="${RUN_GATEWAY_API:-1}"
GATEWAY_API_REF="${GATEWAY_API_REF:-1c39c4baddf3a2c91e93c0324f6777d3cf5b0dfe}"
USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE:-1}"
SUBSTRATE_ROOT="${SUBSTRATE_ROOT:-${WORK_PARENT}/SUBSTRATE_UPSTREAMS}"

AUTO_INSTALL_CERT_MANAGER="${AUTO_INSTALL_CERT_MANAGER:-1}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.19.4}"

HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
declare -a HELM_COMMON_ARGS
HELM_COMMON_ARGS=(--wait --timeout "${HELM_TIMEOUT}" --hide-notes)

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_cert_manager() {
  if kubectl get crd certificates.cert-manager.io issuers.cert-manager.io >/dev/null 2>&1; then
    return 0
  fi

  if [ "${AUTO_INSTALL_CERT_MANAGER}" != "1" ]; then
    echo "Missing cert-manager CRDs; install cert-manager first or set AUTO_INSTALL_CERT_MANAGER=1." >&2
    exit 1
  fi

  echo "Installing cert-manager ${CERT_MANAGER_CHART_VERSION}..."
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    "${HELM_COMMON_ARGS[@]}" \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_CHART_VERSION}" \
    --set crds.enabled=true

  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager --timeout="${HELM_TIMEOUT}"
  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout="${HELM_TIMEOUT}"
  kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-cainjector --timeout="${HELM_TIMEOUT}"
}

add_repos() {
  helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
  helm repo add fluent https://fluent.github.io/helm-charts --force-update >/dev/null
  helm repo add kedacore https://kedacore.github.io/charts --force-update >/dev/null
  helm repo update >/dev/null
}

install_external_secrets() {
  echo "Installing External Secrets ${EXTERNAL_SECRETS_CHART_VERSION}..."
  helm upgrade --install external-secrets external-secrets/external-secrets \
    "${HELM_COMMON_ARGS[@]}" \
    --namespace external-secrets \
    --create-namespace \
    --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
    --set installCRDs=true
}

install_otel_operator() {
  echo "Installing OpenTelemetry Operator ${OTEL_OPERATOR_CHART_VERSION}..."
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    "${HELM_COMMON_ARGS[@]}" \
    --namespace observability \
    --create-namespace \
    --version "${OTEL_OPERATOR_CHART_VERSION}"
}

install_fluent_bit() {
  echo "Installing Fluent Bit ${FLUENT_BIT_CHART_VERSION}..."
  helm upgrade --install fluent-bit fluent/fluent-bit \
    "${HELM_COMMON_ARGS[@]}" \
    --namespace logging \
    --create-namespace \
    --version "${FLUENT_BIT_CHART_VERSION}"
}

install_keda() {
  echo "Installing KEDA ${KEDA_CHART_VERSION}..."
  helm upgrade --install keda kedacore/keda \
    "${HELM_COMMON_ARGS[@]}" \
    --namespace keda \
    --create-namespace \
    --version "${KEDA_CHART_VERSION}"
}

wait_for_labeled_deployments() {
  local namespace="$1"
  local label="$2"
  local deployments

  deployments="$(kubectl -n "${namespace}" get deployment -l "${label}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  if [ -z "${deployments}" ]; then
    echo "No deployments found in namespace=${namespace} label=${label}" >&2
    exit 1
  fi

  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    kubectl -n "${namespace}" wait --for=condition=Available "deployment/${name}" --timeout="${HELM_TIMEOUT}"
  done <<<"${deployments}"
}

wait_for_fluent_bit() {
  local ds
  ds="$(kubectl -n logging get daemonset -l app.kubernetes.io/instance=fluent-bit -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${ds}" ]; then
    echo "Fluent Bit daemonset not found in namespace=logging" >&2
    exit 1
  fi
  kubectl -n logging rollout status "daemonset/${ds}" --timeout="${HELM_TIMEOUT}"
}

verify_crds() {
  echo "Validating External Secrets CRDs..."
  kubectl get crd externalsecrets.external-secrets.io >/dev/null
  kubectl get crd secretstores.external-secrets.io >/dev/null
  kubectl get crd clustersecretstores.external-secrets.io >/dev/null

  echo "Validating OpenTelemetry CRDs..."
  kubectl get crd opentelemetrycollectors.opentelemetry.io >/dev/null
  kubectl get crd instrumentations.opentelemetry.io >/dev/null

  echo "Validating KEDA CRDs..."
  kubectl get crd scaledobjects.keda.sh >/dev/null
  kubectl get crd scaledjobs.keda.sh >/dev/null
  kubectl get crd triggerauthentications.keda.sh >/dev/null
  kubectl get crd clustertriggerauthentications.keda.sh >/dev/null
}

verify_gateway_api() {
  if [ "${RUN_GATEWAY_API}" != "1" ]; then
    return 0
  fi

  USE_LOCAL_SUBSTRATE="${USE_LOCAL_SUBSTRATE}" \
  SUBSTRATE_ROOT="${SUBSTRATE_ROOT}" \
  GATEWAY_API_REF="${GATEWAY_API_REF}" \
    "${SCRIPT_DIR}/verify-phase-00-gateway-api-crds.sh"
}

main() {
  require_cmd kubectl
  require_cmd helm

  verify_gateway_api
  ensure_cert_manager
  add_repos

  install_external_secrets
  install_otel_operator
  install_fluent_bit
  install_keda

  wait_for_labeled_deployments external-secrets "app.kubernetes.io/instance=external-secrets"
  wait_for_labeled_deployments observability "app.kubernetes.io/instance=opentelemetry-operator"
  wait_for_labeled_deployments keda "app.kubernetes.io/instance=keda"
  wait_for_fluent_bit

  verify_crds

  echo "Phase 00/01 runtime verification passed (Gateway API CRDs + External Secrets + OTel Operator + Fluent Bit + KEDA)."
}

main "$@"
