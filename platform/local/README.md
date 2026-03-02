# Local Bootstrap (kind / k3d)

This directory provides a local bootstrap path for validating the current repository-owned manifests and a `CloudNativePG` Postgres smoke test on a disposable cluster.

This path is intentionally **direct `kubectl` + `helm`**, not Argo CD dependent, so it works before the repo is published to a Git remote.

## What It Does

- Creates a local Kubernetes cluster (`kind` or `k3d`)
- Installs the `CloudNativePG` operator (pinned chart version)
- Applies repo base manifests (`platform/base`)
- Applies a test CNPG Postgres cluster (`platform/data/cnpg-test-cluster`)
- Runs a Postgres smoke test job (`platform/data/postgres-smoketest`)

## Prerequisites

- `kubectl`
- `helm`
- `kind` or `k3d`
- `docker`

## Usage

### One-command M0 verification gate (recommended)

`kind` (runs bootstrap + provider discovery smoke + prints PASS/FAIL summary):

```bash
./platform/local/bin/verify-m0.sh
```

`k3d`:

```bash
RUNTIME=k3d ./platform/local/bin/verify-m0.sh
```

Verify an already-running cluster without re-running bootstrap:

```bash
RUN_BOOTSTRAP=0 ./platform/local/bin/verify-m0.sh
```

### One-command M1 policy-provider verification (OPA adapter)

Runs the M0 gate first by default, then builds/loads the local OPA adapter image and verifies:
- `PolicyProvider` discovery (`Ready=True`, `Probed=True`)
- policy evaluation returns both `ALLOW` and `DENY` for test requests
- `validate-bundle` returns `valid=true`

```bash
./platform/local/bin/verify-m1-policy-provider.sh
```

Skip rerunning M0 bootstrap (use existing cluster state):

```bash
RUN_M0=0 ./platform/local/bin/verify-m1-policy-provider.sh
```

Use `k3d`:

```bash
RUNTIME=k3d ./platform/local/bin/verify-m1-policy-provider.sh
```

### One-command evidence-provider verification (memory provider)

Runs the evidence-provider slice against the current cluster and validates:
- `EvidenceProvider` discovery (`Ready=True`, `Probed=True`)
- `record` accepts and returns `evidenceId`
- `finalize-bundle` returns `manifestUri`, `manifestChecksum`, and `itemCount`

Run after M1 policy-provider (default behavior re-runs the policy gate):

```bash
./platform/local/bin/verify-m1-evidence-provider.sh
```

Skip rerunning policy and M0 gates (fast path on an already-good cluster):

```bash
RUN_M1_POLICY=0 RUN_M0=0 ./platform/local/bin/verify-m1-evidence-provider.sh
```

Use `k3d`:

```bash
RUNTIME=k3d ./platform/local/bin/verify-m1-evidence-provider.sh
```

### Negative provider-discovery verification (controller failure modes)

Validates controller status/error handling for:
- bad endpoint URL (probe transport failure)
- wrong `providerType` (contract mismatch)
- `BearerTokenSecret` auth failure (missing secret)

Fast path on your current cluster:

```bash
RUN_M0=0 ./platform/local/bin/verify-m1-provider-discovery-negative.sh
```

Keep the negative test `ExtensionProvider` resources for inspection (instead of auto-cleanup):

```bash
KEEP_RESOURCES=1 ./platform/local/bin/smoke-provider-discovery-negative.sh
```

### M2 mTLS provider-discovery verification (success modes)

Validates the controller success path for:
- `auth.mode: MTLS`
- `auth.mode: MTLSAndBearerTokenSecret`

The script generates a local CA, server cert, and client cert, creates Kubernetes secrets, deploys mTLS fixture providers, and verifies both `ExtensionProvider` resources reconcile to `Ready=True` and `Probed=True`.

Fast path on your current cluster:

```bash
RUN_M1_NEGATIVE=0 ./platform/local/bin/verify-m2-mtls-provider.sh
```

Optionally rerun the M1 negative gate before M2:

```bash
RUN_M1_NEGATIVE=1 RUN_M0=0 ./platform/local/bin/verify-m2-mtls-provider.sh
```

Keep mTLS test resources and generated secrets for inspection:

```bash
KEEP_RESOURCES=1 ./platform/local/bin/smoke-provider-discovery-mtls.sh
```

### Phase 00/01 runtime verification (Gateway API + External Secrets + OTel + Fluent Bit + KEDA)

Installs and validates the Phase 00/01 runtime components on your local cluster:
- Gateway API CRDs
- External Secrets
- OpenTelemetry Operator
- Fluent Bit
- KEDA

This script uses pinned chart versions matching `platform/argocd/apps/phase-00` and `platform/argocd/apps/phase-01`.
If cert-manager CRDs are missing, it installs pinned cert-manager `v1.19.4` first.

```bash
./platform/local/bin/verify-phase-00-01-runtime.sh
```

Run only the Gateway API CRD verifier:

```bash
./platform/local/bin/verify-phase-00-gateway-api-crds.sh
```

Disable cert-manager auto-install (fail fast if missing):

```bash
AUTO_INSTALL_CERT_MANAGER=0 ./platform/local/bin/verify-phase-00-01-runtime.sh
```

### Phase 02 delivery/events verification (Argo Rollouts + Argo Events)

Installs and validates phase 02 components on your local cluster:
- Argo Rollouts controller
- Argo Events controller
- required CRDs for both projects

By default, this script prefers your locally downloaded substrate repos (if present) and otherwise falls back to pinned Git refs.

```bash
./platform/local/bin/verify-phase-02-delivery-events.sh
```

Force remote Git refs instead of local substrate:

```bash
USE_LOCAL_SUBSTRATE=0 ./platform/local/bin/verify-phase-02-delivery-events.sh
```

Remove stale `default/argo-rollouts` resources from earlier test runs:

```bash
CLEANUP_LEGACY_DEFAULT_ROLLOUTS=1 ./platform/local/bin/verify-phase-02-delivery-events.sh
```

### Phase 03 inference verification (KServe standalone)

Installs and validates KServe phase 03 on your local cluster:
- KServe controller deployment (`kserve-controller-manager`)
- Core KServe CRDs (`InferenceService`, `ServingRuntime`, etc.)
- Functional `InferenceService` smoke (`Ready=True` + live predict request)

By default this uses your local `SUBSTRATE_UPSTREAMS` KServe checkout and pins controller image `kserve/kserve-controller:v0.16.0`.
If cert-manager CRDs are missing, the verifier auto-installs pinned cert-manager `v1.19.4` first.
KServe is applied with server-side apply and `--force-conflicts` by default (`FORCE_CONFLICTS=1`) to handle local-cluster migration from earlier client-side applies.

```bash
./platform/local/bin/verify-phase-03-kserve.sh
```

Optionally run Phase 02 first:

```bash
RUN_PHASE_02=1 ./platform/local/bin/verify-phase-03-kserve.sh
```

Force remote Git ref instead of local substrate:

```bash
USE_LOCAL_SUBSTRATE=0 ./platform/local/bin/verify-phase-03-kserve.sh
```

Disable cert-manager auto-install (fail fast if missing):

```bash
AUTO_INSTALL_CERT_MANAGER=0 ./platform/local/bin/verify-phase-03-kserve.sh
```

Disable force-conflicts (only if you want strict conflict failures):

```bash
FORCE_CONFLICTS=0 ./platform/local/bin/verify-phase-03-kserve.sh
```

Disable the functional `InferenceService` smoke (controller/CRD checks only):

```bash
RUN_FUNCTIONAL_SMOKE=0 ./platform/local/bin/verify-phase-03-kserve.sh
```

Run only the functional KServe smoke directly:

```bash
./platform/local/bin/smoke-kserve-inferenceservice.sh
```

Keep smoke resources after run (for inspection):

```bash
KEEP_RESOURCES=1 ./platform/local/bin/smoke-kserve-inferenceservice.sh
```

### Phase 04 policy/evidence over KServe verification

Runs an end-to-end Phase 04 flow on the local cluster:
- selects active `PolicyProvider` and `EvidenceProvider` from `ExtensionProvider` resources (`selection.enabled=true`, highest `selection.priority`, `Ready=True`, `Probed=True`)
- evaluates a policy decision for a KServe inference context
- records the decision/inference event with the evidence provider
- finalizes an evidence bundle and validates manifest fields

By default this script builds/loads local Epydios images (controller/profile/policy/evidence) and runs KServe smoke for request context.
It now also runs a secure auth subflow by default (`RUN_SECURE_AUTH_PATH=1`) that validates:
- policy provider selection and invocation with `auth.mode=MTLS`
- evidence provider selection and invocation with `auth.mode=MTLSAndBearerTokenSecret`

```bash
./platform/local/bin/verify-phase-04-policy-evidence-kserve.sh
```

Run after Phase 03 without re-running Phase 03 install:

```bash
RUN_PHASE_03=0 ./platform/local/bin/verify-phase-04-policy-evidence-kserve.sh
```

Skip local image build/load (if images are already present/pullable):

```bash
RUN_IMAGE_PREP=0 ./platform/local/bin/verify-phase-04-policy-evidence-kserve.sh
```

Disable the secure auth subflow (baseline `auth.mode=None` flow only):

```bash
RUN_SECURE_AUTH_PATH=0 ./platform/local/bin/verify-phase-04-policy-evidence-kserve.sh
```

### M5 runtime orchestration verification (persistent runtime API)

Runs the runtime orchestration service smoke against the local cluster:
- ensures runtime service deployment is healthy (`orchestration-runtime`)
- executes `POST /v1alpha1/runtime/runs` for both ALLOW and DENY inputs
- validates persisted run retrieval via:
  - `GET /v1alpha1/runtime/runs/{runId}`
  - `GET /v1alpha1/runtime/runs?limit=...`
- asserts provider selection fields and decision outcomes are recorded

```bash
./platform/local/bin/verify-m5-runtime-orchestration.sh
```

Fast path on an already prepared cluster (skip bootstrap and image build/load):

```bash
RUN_BOOTSTRAP=0 RUN_IMAGE_PREP=0 ./platform/local/bin/verify-m5-runtime-orchestration.sh
```

### M9.1 runtime API authn/authz skeleton verification

Runs runtime API JWT authn/authz checks against the local cluster:
- optionally runs M5 baseline first
- enables auth for runtime API (`AUTHN_ENABLED=true`) with JWT issuer/audience checks
- asserts:
  - `401 UNAUTHORIZED` for missing/invalid bearer token
  - `403 FORBIDDEN` for role mismatch and disallowed `client_id`
  - success for valid create/read role mappings

```bash
./platform/local/bin/verify-m9-authn-authz.sh
```

Fast path when M5/runtime is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m9-authn-authz.sh
```

### M9.2/M9.3 runtime authz tenancy + audit verification

Runs tenant/project scope and audit checks against the runtime API:
- optionally runs M5 baseline first
- enables runtime authn/authz in-cluster with tenant/project claim mapping
- asserts:
  - cross-tenant and cross-project create/read paths are blocked (`403 FORBIDDEN`)
  - in-tenant create/read/list paths succeed
  - scoped tokens can auto-populate missing `meta.tenantId`/`meta.projectId` when uniquely scoped
  - structured audit events are emitted for authz decisions, provider selection, policy decision, and run completion

```bash
./platform/local/bin/verify-m9-authz-tenancy.sh
```

Fast path when M5/runtime is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m9-authz-tenancy.sh
```

### M9.4 runtime RBAC policy matrix verification

Runs production-style RBAC matrix checks against the runtime API:
- optionally runs M5 baseline first
- enables runtime authn/authz with:
  - OIDC role->permission mapping (`AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON`)
  - tenant/project allow/deny matrix (`AUTHZ_POLICY_MATRIX_JSON`)
- asserts:
  - unknown roles are denied by role mapping
  - reader/operator/admin role permissions are enforced
  - explicit deny policy rules override allow rules
  - requests with no matching allow rule are denied
  - runtime emits structured policy allow/deny audit events

```bash
./platform/local/bin/verify-m9-rbac-matrix.sh
```

Fast path when M5/runtime is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m9-rbac-matrix.sh
```

### M9.5 runtime audit read endpoint verification

Runs runtime audit endpoint checks against the runtime API:
- optionally runs M5 baseline first
- enables runtime authn/authz in-cluster with tenant/project claim mapping
- asserts:
  - unauthenticated audit reads are rejected (`401 UNAUTHORIZED`)
  - authenticated scoped reads succeed
  - cross-tenant records are filtered out for scoped readers
  - `tenantId`, `projectId`, `providerId`, `decision`, and `event` filters behave as expected
  - invalid query parameters (for example `limit=abc`) are rejected (`400 INVALID_LIMIT`)

```bash
./platform/local/bin/verify-m9-audit-read.sh
```

Fast path when M5/runtime is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m9-audit-read.sh
```

### M10.1 provider conformance verification

Runs contract conformance checks across all provider types and auth modes:
- provider types: `ProfileResolver`, `PolicyProvider`, `EvidenceProvider`
- auth modes: `None`, `BearerTokenSecret`, `MTLS`, `MTLSAndBearerTokenSecret`
- verifies discovery (`Ready=True`, `Probed=True`) and endpoint behavior (`healthz`, `capabilities`, contract endpoints)
- includes negative assertions:
  - missing bearer secret for `BearerTokenSecret`
  - mTLS endpoint access without client cert
  - `MTLSAndBearerTokenSecret` endpoint access without bearer token

```bash
./platform/local/bin/verify-m10-provider-conformance.sh
```

Fast path when runtime baseline is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m10-provider-conformance.sh
```

Skip local image build/load if cluster images are already available:

```bash
RUN_IMAGE_PREP=0 ./platform/local/bin/verify-m10-provider-conformance.sh
```

### M10.3 policy grant enforcement verification

Runs non-bypassable grant-token checks for runtime policy decisions:
- optionally runs M5 baseline first
- enables runtime enforcement (`AUTHZ_REQUIRE_POLICY_GRANT=true`)
- asserts:
  - ALLOW-like decision without grant token fails (`500 RUN_EXECUTION_FAILED`)
  - DENY decision still completes without grant token
  - token-emitting ALLOW succeeds and runtime response exposes only token hash/presence (no raw token)

```bash
./platform/local/bin/verify-m10-policy-grant-enforcement.sh
```

Fast path when runtime baseline is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m10-policy-grant-enforcement.sh
```

### M10.6 AIMXS entitlement deny-path verification

Runs runtime AIMXS entitlement boundary checks on the policy-provider path:
- optionally runs M5 baseline first
- applies `aimxs-customer-hosted` mode and local AIMXS contract override for OSS smoke
- enables runtime entitlement enforcement
- asserts:
  - missing entitlement token => `DENY`
  - disallowed SKU => `DENY`
  - missing required feature => `DENY`
  - licensed entitlement payload => `ALLOW`

```bash
./platform/local/bin/verify-m10-entitlement-deny.sh
```

Fast path when runtime baseline is already healthy:

```bash
RUN_M5_BASELINE=0 ./platform/local/bin/verify-m10-entitlement-deny.sh
```

### M10.7 AIMXS customer-hosted packaging evidence verification

Validates release-grade packaging evidence for customer-hosted AIMXS mode:
- consumes private metadata inputs from `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/customer-hosted-release-inputs.vars` by default
- requires strict staging log markers for M10.4/M10.5/M10.6 and full-gate pass
- asserts signed packaging references, SBOM/signature references, air-gapped install/update bundle refs, and support/SLA references
- verifies required runbooks:
  - `docs/runbooks/aimxs-customer-hosted-airgap.md`
  - `docs/runbooks/aimxs-customer-hosted-support-boundary.md`
- writes evidence to:
  - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-7-customer-hosted-packaging-evidence-<timestamp>.json`

```bash
./platform/local/bin/verify-m10-customer-hosted-packaging.sh
```

Override input/evidence paths explicitly:

```bash
INPUT_FILE=../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/customer-hosted-release-inputs.vars \
OUTPUT_DIR=../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs \
./platform/local/bin/verify-m10-customer-hosted-packaging.sh
```

### M7.1 integration verification (M0->M5 critical path)

Runs one end-to-end integration gate across milestones M0 through M5:
- M0 bootstrap + provider discovery
- Phase 00/01 runtime components
- Phase 03 KServe (with functional inference smoke)
- Phase 04 policy/evidence flow (baseline + secure auth, ALLOW + DENY)
- M5 runtime orchestration API smoke

```bash
./platform/local/bin/verify-m7-integration.sh
```

Reuse an already prepared cluster (fast path):

```bash
RUN_M0=0 RUN_PHASE_00_01=0 RUN_M5_BOOTSTRAP=0 ./platform/local/bin/verify-m7-integration.sh
```

Include the M7.2 backup/restore drill in the integration run:

```bash
RUN_M7_2_BACKUP_RESTORE=1 ./platform/local/bin/verify-m7-integration.sh
```

Include M7.3 upgrade-safety validation in the integration run:

```bash
RUN_M7_3_UPGRADE_SAFETY=1 ./platform/local/bin/verify-m7-integration.sh
```

### M7.2 CNPG backup/restore drill

Runs a deterministic backup/restore drill against the CNPG primary:
- seeds a marker row in `aios_core`
- creates a logical backup (`pg_dump`)
- simulates source data loss
- restores into a drill database and verifies marker recovery

```bash
./platform/local/bin/verify-m7-cnpg-backup-restore.sh
```

Keep the generated dump file for inspection:

```bash
KEEP_DUMP_FILE=1 ./platform/local/bin/verify-m7-cnpg-backup-restore.sh
```

### M7.3 upgrade safety gate (N-1 -> N)

Runs upgrade-safety validation for first-party control-plane deployments:
- enforces allowed upgrade path from `platform/upgrade/compatibility-policy.yaml`
- builds current images and simulates N-1 image tags locally
- rolls deployments N-1 -> N and verifies rollout + provider compatibility
- validates ExtensionProvider CRD contract (`v1alpha1` served/storage)

```bash
./platform/local/bin/verify-m7-upgrade-safety.sh
```

Override tested path:

```bash
PREVIOUS_TAG=0.0.9 CURRENT_TAG=0.1.0 ./platform/local/bin/verify-m7-upgrade-safety.sh
```

### Phase 05 distributed compute verification (KubeRay)

Installs and validates the KubeRay operator as an optional next phase:
- installs Helm chart `kuberay/kuberay-operator` (pinned `1.1.0`) in `kuberay-system`
- pins operator image override to `quay.io/kuberay/operator:v1.1.0`
- verifies operator deployment `Available=True`
- verifies Ray CRDs (`rayclusters`, `rayjobs`, `rayservices`, `raycronjobs`)
- runs server-side `RayCluster` API smoke by default (no live workload pods required)
- defaults to the published Helm chart repo (`USE_LOCAL_SUBSTRATE=0`) for release-aligned chart/image compatibility

```bash
./platform/local/bin/verify-phase-05-kuberay.sh
```

Disable the KubeRay API smoke:

```bash
RUN_FUNCTIONAL_SMOKE=0 ./platform/local/bin/verify-phase-05-kuberay.sh
```

Run KubeRay smoke in live-apply mode (creates then deletes the smoke `RayCluster`):

```bash
RUN_LIVE_APPLY=1 ./platform/local/bin/smoke-kuberay-raycluster.sh
```

### Production hardening baseline verification

Applies and validates hardening scaffolding:
- NetworkPolicies for controller/provider egress constraints
- ServiceMonitor + PrometheusRule (when monitoring CRDs are present)
- secret/cert rotation checks for provider auth secret refs
- admission enforcement (immutable image digests; optional Kyverno signed-image policy)

```bash
./platform/local/bin/verify-prod-hardening-baseline.sh
```

Run admission-only verification:

```bash
./platform/local/bin/verify-admission-enforcement.sh
```

Require signed-image policy (Kyverno must already be installed):

```bash
APPLY_SIGNED_IMAGE_POLICY=1 REQUIRE_SIGNED_IMAGE_POLICY=1 ./platform/local/bin/verify-admission-enforcement.sh
```

Run only secret/cert rotation checks:

```bash
./platform/local/bin/verify-secret-cert-rotation.sh
```

Require at least one mTLS provider reference and use a tighter threshold:

```bash
FAIL_ON_NO_MTLS_REFS=1 MIN_TLS_VALIDITY_DAYS=60 ./platform/local/bin/verify-secret-cert-rotation.sh
```

### Monitoring stack bootstrap (pilot/staging)

Installs a minimal `kube-prometheus-stack` profile suitable for local pilot validation and
configures selectors to pick up repository-owned `ServiceMonitor` and `PrometheusRule` objects.

```bash
./platform/local/bin/bootstrap-monitoring-stack.sh
```

Pin a specific chart version:

```bash
CHART_VERSION=79.2.0 ./platform/local/bin/bootstrap-monitoring-stack.sh
```

### Monitoring alert-path verification

Validates M8.4 monitoring/alert behavior:
- monitoring CRDs present
- Epydios ServiceMonitor/PrometheusRule loaded
- Prometheus API sees Epydios rules
- synthetic alert transitions to firing and is visible via Alertmanager API

```bash
./platform/local/bin/verify-monitoring-alerts.sh
```

Auto-install monitoring stack before verification:

```bash
AUTO_INSTALL_MONITORING_STACK=1 ./platform/local/bin/verify-monitoring-alerts.sh
```

### AIMXS external-boundary verification

Validates AIMXS plug-in boundary constraints:
- `internal/aimxs/slot.go` contract exists and contains required adapter interfaces
- no direct AIMXS module dependency/import leakage into OSS module graph
- AIMXS example provider endpoint uses HTTPS and secure auth mode
- boundary documentation includes conformance + failure-handling expectations

```bash
./platform/local/bin/verify-aimxs-boundary.sh
```

### AIMXS local dev loopback profile (pre-private endpoint)

Registers a dev-only AIMXS placeholder provider against the OSS local policy service, so you can validate contract/routing behavior before private AIMXS is reachable:

```bash
kubectl apply -f examples/aimxs/extensionprovider-policy-local-dev.yaml
kubectl -n epydios-system patch extensionprovider oss-policy-opa --type=merge -p '{"spec":{"selection":{"enabled":false,"priority":90}}}'
kubectl -n epydios-system patch extensionprovider aimxs-policy-local-dev --type=merge -p '{"spec":{"selection":{"enabled":true,"priority":850}}}'
```

Switch back to secure/private AIMXS registration:

```bash
kubectl apply -f examples/aimxs/extensionprovider-policy-mtls-bearer.yaml
kubectl -n epydios-system patch extensionprovider aimxs-policy-local-dev --type=merge -p '{"spec":{"selection":{"enabled":false,"priority":850}}}'
kubectl -n epydios-system patch extensionprovider aimxs-policy-primary --type=merge -p '{"spec":{"selection":{"enabled":true,"priority":900}}}'
```

The local loopback profile is local-only and must not be promoted to staging/prod.

### AIMXS deployment mode packs

Apply policy-routing mode manifests directly:

```bash
kubectl apply -k platform/modes/oss-only
kubectl apply -k platform/modes/aimxs-hosted
kubectl apply -k platform/modes/aimxs-customer-hosted
```

### PR CI gate parity (kind, ephemeral)

GitHub Actions PRs run `Phase 00/01 + Phase 02 + Phase 03 + Phase 04` with functional KServe smoke enabled using pinned remote refs (no local substrate dependency).

Run the same gate locally:

```bash
./platform/ci/bin/pr-kind-phase03-gate.sh
```

Use fast mode for quick local iteration (Phase 03 core only by default):

```bash
GATE_MODE=fast ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Use full mode for CI parity (default):

```bash
GATE_MODE=full ./platform/ci/bin/pr-kind-phase03-gate.sh
```

`GATE_MODE=full` now enforces required checks for:
- M7 integration (`M7.1`) + backup/restore (`M7.2`) + upgrade safety (`M7.3`)
- secure Phase 04 path + rotation (`FAIL_ON_NO_MTLS_REFS=1`)
- production hardening baseline
- AIMXS external-boundary verification

Use `GATE_MODE=fast` for local skip/override workflows.

Use profile-driven gate execution:

```bash
PROFILE=local-fast ./platform/ci/bin/run-gate-profile.sh
PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh
PROFILE=prod-full ./platform/ci/bin/run-gate-profile.sh
```

Disable Phase 00/01 runtime install/check in the gate (fast path):

```bash
RUN_PHASE_00_01=0 ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Keep Phase 00/01 enabled but skip Gateway API CRD verification:

```bash
RUN_GATEWAY_API=0 ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Disable Phase 04 gate in fast mode only:

```bash
GATE_MODE=fast RUN_PHASE_04=0 ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Keep Phase 04 enabled but disable the secure auth Phase 04 subflow (fast mode only):

```bash
GATE_MODE=fast RUN_PHASE_04_SECURE=0 ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Enable optional Phase 05 KubeRay gate:

```bash
RUN_PHASE_05=1 ./platform/ci/bin/pr-kind-phase03-gate.sh
```

Use a specific cluster name (for example, if you want to avoid creating a second kind cluster with the same host-port mappings):

```bash
CLUSTER_NAME=epydios-dev ./platform/ci/bin/pr-kind-phase03-gate.sh
```

### Provenance lock verification

Validate lockfile structure and pin quality (development mode; unresolved release fields reported as warnings):

```bash
./platform/local/bin/verify-provenance-lockfiles.sh
```

Run strict release-grade validation (blocking on required unresolved digests/licenses):

```bash
STRICT=1 ./platform/local/bin/verify-provenance-lockfiles.sh
```

Sync image digests from cluster runtime image IDs:

```bash
./platform/local/bin/sync-provenance-image-digests.sh
```

Allow registry pulls for missing digests:

```bash
ALLOW_DOCKER_PULL=1 ./platform/local/bin/sync-provenance-image-digests.sh
```

### kind

```bash
./platform/local/bin/bootstrap-kind.sh
```

With Epydios local image build/load + provider discovery smoke:

```bash
WITH_SYSTEM_SMOKETEST=1 ./platform/local/bin/bootstrap-kind.sh
```

### k3d

```bash
./platform/local/bin/bootstrap-k3d.sh
```

With Epydios local image build/load + provider discovery smoke:

```bash
WITH_SYSTEM_SMOKETEST=1 ./platform/local/bin/bootstrap-k3d.sh
```

## Local Image Helpers

- `platform/local/bin/build-local-images.sh` builds the Epydios controller/provider images locally using `build/docker/Dockerfile.go-binary`
- `platform/local/bin/build-local-images-amd64.sh` builds Intel/x86_64 images (`DOCKER_PLATFORM=linux/amd64`) for release-aligned validation
- `platform/local/bin/load-local-images-kind.sh` loads local images into an existing `kind` cluster
- `platform/local/bin/load-local-images-k3d.sh` imports local images into an existing `k3d` cluster
- `platform/local/bin/smoke-provider-discovery.sh` applies `platform/system` and verifies `ExtensionProvider` discovery status (`Ready=True`, `Probed=True`)
- `platform/local/bin/smoke-provider-discovery-negative.sh` applies negative `ExtensionProvider` cases and verifies `Ready=False` / `Probed=False` with expected errors
- `platform/local/bin/smoke-provider-discovery-mtls.sh` deploys mTLS fixture providers and verifies `MTLS` and `MTLSAndBearerTokenSecret` success paths
- `platform/local/bin/smoke-policy-provider-opa.sh` applies `platform/providers/oss-policy-opa` and runs policy evaluate/validate smoke checks
- `platform/local/bin/smoke-evidence-provider-memory.sh` applies `platform/providers/oss-evidence-memory` and runs evidence record/finalize smoke checks
- `platform/local/bin/smoke-kserve-inferenceservice.sh` applies `platform/tests/kserve-smoke` and validates a live `InferenceService` predict request
- `platform/local/bin/verify-m1-policy-provider.sh` runs the M1 policy-provider verification gate
- `platform/local/bin/verify-m1-evidence-provider.sh` runs the evidence-provider verification gate
- `platform/local/bin/verify-m1-provider-discovery-negative.sh` runs the negative provider-discovery verification gate
- `platform/local/bin/verify-m2-mtls-provider.sh` runs the mTLS provider-discovery verification gate
- `platform/local/bin/verify-phase-00-gateway-api-crds.sh` installs and verifies phase 00 Gateway API CRDs
- `platform/local/bin/verify-phase-00-01-runtime.sh` installs and verifies Phase 00/01 runtime components (Gateway API CRDs, External Secrets, OTel Operator, Fluent Bit, KEDA)
- `platform/local/bin/verify-phase-02-delivery-events.sh` installs and verifies phase 02 delivery/event components
- `platform/local/bin/verify-phase-03-kserve.sh` installs and verifies phase 03 KServe components
- `platform/local/bin/verify-phase-04-policy-evidence-kserve.sh` runs phase 04 policy/evidence flow against KServe request context
- `platform/local/bin/verify-phase-05-kuberay.sh` installs and verifies optional phase 05 KubeRay components
- `platform/local/bin/verify-m10-provider-conformance.sh` validates provider contract/auth-mode conformance across ProfileResolver/PolicyProvider/EvidenceProvider
- `platform/local/bin/verify-m10-policy-grant-enforcement.sh` validates required grant-token enforcement (`no token => no execution` for non-DENY decisions)
- `platform/local/bin/verify-m10-deployment-modes.sh` validates three deployment-mode routing transitions (`oss-only`, `aimxs-hosted`, `aimxs-customer-hosted`) under one provider contract
- `platform/local/bin/verify-m10-no-egress-local-aimxs.sh` validates customer-hosted local AIMXS mode under scoped no-egress network policy constraints
- `platform/local/bin/verify-m10-entitlement-deny.sh` validates runtime entitlement deny-path assertions and licensed ALLOW behavior on AIMXS policy routing
- `platform/local/bin/verify-m10-customer-hosted-packaging.sh` validates customer-hosted AIMXS packaging evidence requirements (signed package refs, SBOM/signature refs, air-gapped install/update bundles, and support/SLA references)
- `platform/local/bin/verify-m7-integration.sh` runs an end-to-end M0->M5 critical-path integration gate (optionally includes M7.2)
- `platform/local/bin/verify-m7-cnpg-backup-restore.sh` runs the M7.2 CNPG backup/restore drill
- `platform/local/bin/verify-m7-upgrade-safety.sh` runs the M7.3 N-1->N upgrade safety gate
- `platform/local/bin/smoke-kuberay-raycluster.sh` validates `RayCluster` API admission via server-side dry-run (or live apply mode)
- `platform/local/bin/verify-secret-cert-rotation.sh` validates auth secret/token presence and TLS certificate expiry windows for provider references
- `platform/local/bin/verify-prod-hardening-baseline.sh` applies hardening scaffolding (NetworkPolicies, monitoring resources when available, admission enforcement) and runs rotation checks
- `platform/local/bin/verify-admission-enforcement.sh` validates admission-deny behavior for mutable tags and optional signed-image enforcement via Kyverno
- `platform/local/bin/bootstrap-monitoring-stack.sh` installs a local kube-prometheus-stack profile for pilot/staging monitoring validation
- `platform/local/bin/verify-monitoring-alerts.sh` validates Prometheus/Alertmanager rule load + synthetic firing alert path
- `platform/local/bin/verify-aimxs-boundary.sh` verifies AIMXS stays an external HTTPS plug-in boundary (slot contract + import boundary + manifest auth constraints)
- `platform/local/bin/verify-provenance-lockfiles.sh` validates chart/image/CRD/license lockfiles (development and strict modes)
- `platform/local/bin/sync-provenance-image-digests.sh` fills `provenance/images.lock.yaml` digests from running cluster image IDs and optional registry pulls

For release-aligned Intel targets, use:

```bash
./platform/local/bin/build-local-images-amd64.sh
```

For native local speed (for example Apple Silicon), keep using `build-local-images.sh`.

## Notes

- These scripts validate the CNPG/Postgres local path only. They do not install the full control-plane operator stack yet.
- `platform/system` is not applied by default. Enable `WITH_SYSTEM_SMOKETEST=1` to build and load local images, then run the provider discovery smoke path.
- The test Postgres cluster and credentials are for local development only. Replace before any shared environment usage.
