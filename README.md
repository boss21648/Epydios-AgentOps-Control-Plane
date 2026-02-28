# Epydios AgentOps Control Plane

`Epydios AgentOps Control Plane` is the open-source Kubernetes control plane for AI/agent workloads, governance, and platform operations.

`AIOS` can remain the umbrella vision/codename. The OSS product name stays specific and accurate: a control plane, not a full operating system.

## Scope (Current Phase)

This repository is for the enterprise Kubernetes control plane baseline:

- Control-plane infrastructure and add-ons
- Versioned extension interfaces for private/public policy/evidence/profile providers
- Provenance, licensing, and dependency lockfiles
- Deployment and integration scaffolding

## AIMXS Strategy

AIMXS is treated as a private plug-in target, not a hard compile-time dependency of the OSS control plane.

- OSS core exposes versioned extension interfaces
- OSS ships baseline providers (profile resolver + OPA policy + memory evidence)
- AIMXS plugs in via the same interfaces under separate licensing
- AIMXS integration remains network-boundary only (HTTPS/mTLS preferred), and runtime can enforce non-bypassable grant semantics (`AUTHZ_REQUIRE_POLICY_GRANT=true`)

This keeps the OSS baseline fully runnable while preserving AIMXS as a differentiating module.

## Baseline Build Sequence (Agreed)

1. `Postgres + CloudNativePG`
2. `cert-manager + External Secrets`
3. `Gateway API`
4. `OTel Operator` (with OTel Collector already present in substrate)
5. `Fluent Bit` (logs -> OpenSearch)
6. `KEDA`
7. `Argo Rollouts + Argo Events`
8. `KServe` (before `KubeRay`)
9. `KubeRay` (when distributed workloads justify it)

## Repo Layout

- `contracts/extensions/v1alpha1/` versioned extension interfaces and provider registration CRD
- `docs/` architecture and implementation notes
  - includes `pilot-readiness-signoff-draft.md` and runbooks under `docs/runbooks/`
  - runbooks include incident triage, Postgres backup/restore, monitoring ownership/rollout, and AIMXS private SDK publication process
- `platform/base/` cluster base manifests (namespaces, shared CRDs)
- `platform/overlays/` environment overlays (for example `production`)
- `platform/data/` local/test data plane manifests (CNPG test cluster, Postgres smoke test)
- `platform/providers/` optional provider deployment manifests for milestone validation (for example, OSS OPA policy provider)
- `platform/ci/` CI entrypoints used by GitHub Actions gates
  - includes profile runner `platform/ci/bin/run-gate-profile.sh` and environment profiles under `platform/ci/profiles/`
- `platform/baseline/` ordered component catalog and rollout plan
- `platform/local/` local `kind`/`k3d` bootstrap configs and scripts
- `provenance/` lockfiles for charts, images, CRDs, licenses
- `providers/` provider implementation configs and baselines
  - includes OSS `ProfileResolver`, OSS `PolicyProvider` (OPA adapter), and OSS `EvidenceProvider` (memory)
- `cmd/control-plane-runtime/` persistent orchestration runtime API (Postgres-backed run lifecycle)

## Relationship to Workspace-Level Substrate Cache

The workspace includes upstream source clones and backup zips in:

- `../SUBSTRATE_UPSTREAMS/`
- `../SUBSTRATE_UPSTREAMS/ZIPS/`
- `../provenance/third_party_sources.yaml`

This repository consumes pinned versions from lockfiles and does not depend on local source checkouts to build or deploy.
