# AIMXS Private SDK Publication

Last updated: 2026-03-01

## Purpose

Define the release process for the private AIMXS SDK/reference adapter while keeping OSS control-plane boundaries intact.

## Boundary Contract

1. AIMXS SDK implements only the slot boundary in:
   - `internal/aimxs/slot.go`
2. AIMXS SDK is not imported by this OSS module.
3. AIMXS provider endpoints are exposed as `ExtensionProvider` resources over HTTPS.
4. Secure auth modes are required:
   - `MTLS`
   - `MTLSAndBearerTokenSecret`

## Private Repository Packaging

1. Build one private module/repo containing:
   - Slot resolver implementation
   - Slot registry implementation
   - Provider adapter(s) for policy/evidence/profile use-cases
2. Produce at least one publishable artifact:
   - OCI image for provider runtime
   - optional private SDK package for internal consumers
3. Version using semver tags aligned to contract compatibility.

## Publication Workflow

1. Run private SDK/unit tests in private repo.
2. Run OSS boundary checks in this repo:
   - `./platform/local/bin/verify-aimxs-boundary.sh`
   - `./platform/local/bin/verify-m10-policy-grant-enforcement.sh`
   - `./platform/local/bin/verify-m10-aimxs-private-release.sh`
   - `./platform/local/bin/verify-m10-customer-hosted-packaging.sh`
3. Build and push private AIMXS provider image(s).
4. Register/upgrade AIMXS `ExtensionProvider` manifests in staging.
5. Run full staging gate profile:
   - `PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh`
6. Record artifact digests and signed release notes in private release evidence.

## Required Evidence For Completion

1. First private SDK release tag published.
2. First private AIMXS provider digest captured (OCI image digest preferred; artifact digest accepted for private/offline release packaging).
3. Staging full gate pass with AIMXS provider endpoints.
4. No OSS module dependency leakage detected by boundary verifier.
5. Non-bypassable grant enforcement proof captured (`no token => no execution`) for non-`DENY` decisions.
6. Customer-hosted packaging evidence captured (signed package ref + SBOM/signature + air-gapped install/update + support/SLA refs).

## OSS Evidence Artifacts (M10.2)

1. Input metadata:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/private-release-inputs.vars` (default)
   - `provenance/aimxs/private-release-inputs.vars` (repo-local fallback for offline/local-only usage)
2. Generated evidence:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-2-private-release-evidence-<timestamp>.json`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-2-private-release-evidence-<timestamp>.json.sha256`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-2-private-release-evidence-latest.json`

## OSS Evidence Artifacts (M10.7)

1. Input metadata:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/customer-hosted-release-inputs.vars` (default)
   - `provenance/aimxs/customer-hosted-release-inputs.vars` (repo-local fallback for offline/local-only usage)
2. Generated evidence:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-7-customer-hosted-packaging-evidence-<timestamp>.json`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-7-customer-hosted-packaging-evidence-<timestamp>.json.sha256`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/aimxs/m10-7-customer-hosted-packaging-evidence-latest.json`

## Rollback

1. Revert `ExtensionProvider` selection to OSS baseline providers.
2. Keep AIMXS provider CRs registered but disabled (`selection.enabled=false`) for diagnosis.
3. Re-run Phase 04 and M5 gates to confirm baseline behavior.
