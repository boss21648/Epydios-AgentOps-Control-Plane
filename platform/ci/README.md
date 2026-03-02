# CI Gates

This directory contains CI entrypoint scripts invoked by GitHub Actions.

## Current Gate

- `bin/pr-kind-phase03-gate.sh`
  - Always runs mandatory QC preflight first via `bin/qc-preflight.sh`:
    - `go test ./...`
    - shell syntax checks for `platform/**/*.sh`
    - `kubectl kustomize` render checks for all `platform/**/kustomization.yaml`
  - Ensures a local kind cluster exists
  - Supports `GATE_MODE=full|fast`:
    - `full` (default): strict CI parity with required M7 + hardening + AIMXS boundary checks
    - `fast`: quick local iteration (skips heavy phases unless explicitly re-enabled)
  - Runs Phase 00/01 runtime gate:
    - `RUN_PHASE_00_01=1`
    - `RUN_GATEWAY_API=1` (Gateway API CRDs)
    - runtime stack: External Secrets, OTel Operator, Fluent Bit, KEDA
  - Runs Phase 03 verification with:
    - `RUN_PHASE_02=1` (Argo Rollouts + Argo Events install/verify)
    - `RUN_FUNCTIONAL_SMOKE=1` (live `InferenceService` prediction smoke)
    - `USE_LOCAL_SUBSTRATE=0` (pinned remote refs only)
  - Runs Phase 04 verification by default:
    - `RUN_PHASE_04=1` (provider selection + policy decision + evidence bundle handoff over KServe context)
    - `RUN_PHASE_04_SECURE=1` (secure subflow with `MTLS` policy provider + `MTLSAndBearerTokenSecret` evidence provider)
  - Runs M5 runtime orchestration verification by default:
    - `RUN_PHASE_RUNTIME=1` (runtime API create/list/get + ALLOW/DENY execution)
    - `RUN_PHASE_RUNTIME_BOOTSTRAP=1` (ensures CNPG/Postgres substrate before runtime smoke)
    - `RUN_PHASE_RUNTIME_IMAGE_PREP=1` (build/load runtime and provider images before runtime smoke)
  - M9.1 runtime authn/authz skeleton verification:
    - `RUN_M9_AUTHN_AUTHZ=1` in full mode (required)
    - `RUN_M9_AUTHN_AUTHZ=0` default in fast mode
    - runs `platform/local/bin/verify-m9-authn-authz.sh`
    - validates JWT authn/authz behavior (`401`, `403`, and positive role/client-id paths)
  - M9.2/M9.3 tenant/project authz + runtime audit verification:
    - `RUN_M9_AUTHZ_TENANCY=1` in full mode (required)
    - `RUN_M9_AUTHZ_TENANCY=0` default in fast mode
    - runs `platform/local/bin/verify-m9-authz-tenancy.sh`
    - validates cross-tenant/cross-project denials and required audit event emission
  - M9.4 RBAC policy matrix verification:
    - `RUN_M9_RBAC_MATRIX=1` in full mode (required)
    - `RUN_M9_RBAC_MATRIX=0` default in fast mode
    - runs `platform/local/bin/verify-m9-rbac-matrix.sh`
    - validates OIDC role mapping + tenant/project allow/deny policy matrix behavior
  - M9.5 runtime audit-read endpoint verification:
    - `RUN_M9_AUDIT_READ=1` in full mode (required)
    - `RUN_M9_AUDIT_READ=0` default in fast mode
    - runs `platform/local/bin/verify-m9-audit-read.sh`
    - validates authenticated audit endpoint reads, scoped tenant/project filtering, and provider/decision query filters
  - M9.6 policy lifecycle + run query/export + retention controls verification:
    - `RUN_M9_POLICY_LIFECYCLE=1` in full mode (required)
    - `RUN_M9_POLICY_LIFECYCLE=0` default in fast mode
    - runs `platform/local/bin/verify-m9-policy-lifecycle-and-run-query.sh`
    - validates lifecycle mode (`observe|enforce`), run filtering/search, CSV/JSONL export, and retention prune dry-run behavior
  - M10.1 provider conformance verification:
    - `RUN_M10_PROVIDER_CONFORMANCE=1` in full mode (required)
    - `RUN_M10_PROVIDER_CONFORMANCE=0` default in fast mode
    - runs `platform/local/bin/verify-m10-provider-conformance.sh`
    - validates provider contracts across `ProfileResolver`, `PolicyProvider`, `EvidenceProvider`
    - validates auth matrix: `None`, `BearerTokenSecret`, `MTLS`, `MTLSAndBearerTokenSecret`
    - includes negative checks (missing bearer secret, no mTLS client cert, missing bearer on `MTLSAndBearerTokenSecret`)
  - M10.3 policy grant enforcement verification:
    - `RUN_M10_POLICY_GRANT_ENFORCEMENT=1` in full mode (required)
    - `RUN_M10_POLICY_GRANT_ENFORCEMENT=0` default in fast mode
    - runs `platform/local/bin/verify-m10-policy-grant-enforcement.sh`
    - validates non-bypassable runtime gating (`AUTHZ_REQUIRE_POLICY_GRANT=true`):
      - non-DENY decision without grant token fails
      - DENY remains executable without token
      - ALLOW with token succeeds and token is redacted from runtime response payloads
  - M10.4 deployment-mode switching verification:
    - `RUN_M10_DEPLOYMENT_MODES=1` in full mode (required)
    - `RUN_M10_DEPLOYMENT_MODES=0` default in fast mode
    - runs `platform/local/bin/verify-m10-deployment-modes.sh`
    - validates policy-provider routing transitions across:
      - `platform/modes/oss-only`
      - `platform/modes/aimxs-hosted`
      - `platform/modes/aimxs-customer-hosted`
    - confirms all three modes stay on one `ExtensionProvider` contract surface
  - M10.5 customer-hosted no-egress verification:
    - `RUN_M10_NO_EGRESS_LOCAL_AIMXS=1` in full mode (required)
    - `RUN_M10_NO_EGRESS_LOCAL_AIMXS=0` default in fast mode
    - runs `platform/local/bin/verify-m10-no-egress-local-aimxs.sh`
    - validates local/customer-hosted policy path succeeds while external egress is blocked by a scoped runtime NetworkPolicy
  - M10.6 AIMXS entitlement deny-path verification:
    - `RUN_M10_ENTITLEMENT_DENY=1` in full mode (required)
    - `RUN_M10_ENTITLEMENT_DENY=0` default in fast mode
    - runs `platform/local/bin/verify-m10-entitlement-deny.sh`
    - validates runtime entitlement boundary:
      - missing entitlement token => `DENY`
      - disallowed SKU => `DENY`
      - missing required feature => `DENY`
      - licensed entitlement payload => `ALLOW`
  - M10.2 AIMXS private release evidence verification:
    - `RUN_M10_AIMXS_PRIVATE_RELEASE=1` in full mode (required)
    - `RUN_M10_AIMXS_PRIVATE_RELEASE=0` default in fast mode
    - runs `platform/local/bin/verify-m10-aimxs-private-release.sh`
    - validates first private AIMXS SDK/provider release evidence and staging strict-proof assertions
    - reads `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/private-release-inputs.vars` by default for private release metadata (falls back to repo-local path only if present)
  - M10.7 AIMXS customer-hosted packaging evidence verification:
    - `RUN_M10_CUSTOMER_HOSTED_PACKAGING=1` in full mode (required)
    - `RUN_M10_CUSTOMER_HOSTED_PACKAGING=0` default in fast mode
    - runs `platform/local/bin/verify-m10-customer-hosted-packaging.sh`
    - validates customer-hosted packaging references (signed image/artifact + SBOM + air-gapped install/update bundles + support/SLA docs)
    - reads `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/customer-hosted-release-inputs.vars` by default for private customer-hosted release metadata (falls back to repo-local path only if present)
  - M9 runtime authz checks in full mode (required, no skips):
    - `RUN_M9_AUTHN_AUTHZ=1`
    - `RUN_M9_AUTHZ_TENANCY=1`
    - `RUN_M9_RBAC_MATRIX=1`
    - `RUN_M9_AUDIT_READ=1`
    - `RUN_M9_POLICY_LIFECYCLE=1`
    - Full mode enforces all M9 checks and exits if overridden to disabled values.
  - M10 provider conformance check in full mode (required, no skips):
    - `RUN_M10_PROVIDER_CONFORMANCE=1`
    - `RUN_M10_POLICY_GRANT_ENFORCEMENT=1`
    - `RUN_M10_DEPLOYMENT_MODES=1`
    - `RUN_M10_NO_EGRESS_LOCAL_AIMXS=1`
    - `RUN_M10_ENTITLEMENT_DENY=1`
    - `RUN_M10_AIMXS_PRIVATE_RELEASE=1`
    - `RUN_M10_CUSTOMER_HOSTED_PACKAGING=1`
    - Full mode enforces M10.1 + M10.2 + M10.3 + M10.4 + M10.5 + M10.6 + M10.7 and exits if overridden to disabled value.
  - M7 reliability suite in full mode (required, no skips):
    - `RUN_M7_INTEGRATION=1` (M0->M5 critical path through `platform/local/bin/verify-m7-integration.sh`)
    - `RUN_M7_BACKUP_RESTORE=1` (M7.2 CNPG backup/restore drill)
    - `RUN_M7_UPGRADE_SAFETY=1` (M7.3 N-1->N upgrade safety)
    - Full mode enforces these checks and exits if overridden to disabled values.
  - In fast mode these remain optional and default to disabled.
  - Optionally runs Phase 05 verification:
    - `RUN_PHASE_05=0` (disabled by default)
    - `RUN_PHASE_05_FUNCTIONAL_SMOKE=1` (server-side `RayCluster` API smoke when Phase 05 is enabled)
  - Runs production placeholder guard in full mode:
    - `RUN_PRODUCTION_PLACEHOLDER_CHECK=1` in full mode (required)
    - `RUN_PRODUCTION_PLACEHOLDER_CHECK=0` default in fast mode
    - runs `platform/ci/bin/check-production-placeholders.sh`
    - fails if production manifests include placeholder markers such as `replace-with-*` or `example.com`
  - Runs provenance lock verification by default:
    - `RUN_PROVENANCE_CHECK=1`
    - `PROVENANCE_STRICT=1` (release-grade blocking mode enabled by default)
  - Runs secret/cert rotation checks by default:
    - `RUN_ROTATION_CHECK=1`
    - `MIN_TLS_VALIDITY_DAYS=30`
    - `FAIL_ON_NO_MTLS_REFS=1` (full mode enforces secure mTLS provider references)
  - Runs production hardening baseline apply/verify by default in full mode:
    - `RUN_HARDENING_BASELINE=1`
    - `APPLY_NETWORK_POLICIES=1`
    - `APPLY_MONITORING_RESOURCES=auto`
    - `REQUIRE_MONITORING_CRDS=0` (set to `1` in staging/prod gates where monitoring stack must exist)
    - `RUN_MONITORING_ALERT_SMOKE=0` (optional heavy check; uses Prometheus/Alertmanager APIs)
    - `AUTO_INSTALL_MONITORING_STACK=0` (local/staging helper; keep disabled in CI unless explicitly needed)
    - `MONITORING_NAMESPACE=monitoring`
    - `MONITORING_RELEASE_NAME=kube-prometheus-stack`
    - `RUN_ADMISSION_ENFORCEMENT_CHECK=1` (required in full mode)
    - `APPLY_SIGNED_IMAGE_POLICY=1` (required in full mode; strict profiles must run signed-image checks)
    - `REQUIRE_SIGNED_IMAGE_POLICY=1` (required in full mode; strict profiles fail if Kyverno/signed-policy path is unavailable)
  - Runs AIMXS external-boundary verification by default in full mode:
    - `RUN_AIMXS_BOUNDARY_CHECK=1`
    - verifies slot contract boundary, no private AIMXS dependency leakage, and HTTPS/auth constraints in AIMXS example manifests.

The default GitHub Actions workflow is:

- `.github/workflows/pr-kind-phase03-gate.yml`

## Gate Profiles

Use profile-driven execution for environment-specific defaults:

- `bin/run-gate-profile.sh`
- profiles in `platform/ci/profiles/*.env`

Profiles:

1. `local-fast` (developer speed path)
2. `staging-full` (strict monitoring required)
3. `prod-full` (strict monitoring required)

Examples:

```bash
PROFILE=local-fast ./platform/ci/bin/run-gate-profile.sh
PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh
PROFILE=prod-full ./platform/ci/bin/run-gate-profile.sh
```

Monitoring ownership and rollout policy is documented in:

- `docs/runbooks/monitoring-ownership-rollout.md`

## Release Workflow (M6.1 + M6.2)

- `.github/workflows/release-images-ghcr.yml`
  - Triggers on tag push (`v*`) and manual dispatch
  - Builds all Epydios binaries into OCI images via `build/docker/Dockerfile.go-binary`
  - Pushes to GHCR by default (manual dispatch can disable push for dry-run validation)
  - Signs pushed image digests with keyless cosign (GitHub OIDC)
  - Attests pushed image digests with a release predicate and verifies both signature/attestation
  - Generates SPDX-JSON SBOM per pushed image
  - Runs blocking vulnerability gate (`Trivy`) on pushed digest refs
    - default blocking threshold: `CRITICAL`
    - configurable with workflow inputs (`vuln_fail_severities`, `vuln_ignore_unfixed`)
  - Publishes a per-component digest artifact and an aggregated manifest:
    - `release-image-digests.json`
    - `release-image-digests.md`
  - Auto-syncs `provenance/images.lock.yaml` from aggregated release digests (artifact output):
    - `release-images-lockfile-sync` (contains synced lockfile + diff)
  - Runs strict provenance validation on the synced lockfile artifact before publish:
    - `go run ./cmd/provenance-lock-check -strict -repo-root dist/repo-root`
    - blocks artifact publication if the sync result violates strict policy
  - Aggregated digest manifest is the lockfile sync input and audit artifact
  - Local artifact-ingest helper (for post-release lock sync in this workspace):
    - `ARTIFACT_DIR=<release-artifact-dir> ./platform/local/bin/ingest-release-artifacts.sh`
