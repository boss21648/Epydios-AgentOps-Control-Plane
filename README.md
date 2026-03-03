# Epydios AgentOps Control Plane

**Policy-driven control plane for AI and agent workflows on Kubernetes.**

Epydios AgentOps Control Plane gives platform and security teams one place to govern AI runtime behavior, enforce policy, capture evidence and operate safely across environments.

## Overview
Profile Provider = “What context/profile should we apply?”
- Looks at your request fields (tenant, project, environment, sensitivity, etc.)
- Returns a profileId like EPYDIOS_PROFILE_DEV_FAST_V1 or EPYDIOS_PROFILE_HARDENED_V1

Policy Provider = “Given this request + profile, should we allow it?”
- Approve/deny decision is made
- Returns: ALLOW or DENY
- Reasons explaining why are provided

Evidence Provider = “Record what happened.”
- Stores the decision and related data for audit

It is designed as an **enterprise-ready baseline**: strong controls, clear extension contracts and repeatable promotion gates.

## Features

- **Governed execution**: policy decision + evidence capture are first-class runtime paths.
- **Extensible by contract**: swap providers without changing control-plane internals.
- **Security-first operations**: authn/authz, tenancy scoping, audit trails, signed+pinned image admission.
- **Promotion discipline**: strict staging/prod gates with provenance artifacts.

### Core platform

- Kubernetes-native control-plane components
- Postgres/CNPG-backed runtime state
- Runtime orchestration API with lifecycle/query/export controls
- Delivery/event and model-serving baseline (Argo + KServe path)

### Security and governance

- OIDC/JWT authn/authz for runtime API
- Tenant/project isolation checks
- Structured audit events and scoped audit read endpoint
- Provider auth modes:
  - `None`
  - `BearerTokenSecret`
  - `MTLS`
  - `MTLSAndBearerTokenSecret`
- Policy grant enforcement and entitlement-deny path assertions

### Production hardening

- NetworkPolicy baseline (controller/provider/runtime boundaries)
- ServiceMonitor + PrometheusRule coverage
- Secret/cert rotation checks
- Admission enforcement for immutable/signed images
- DR game day + rollback/failure-injection verification paths

## Deployment Modes

| Mode | Provider target | Network expectation | User |
|---|---|---|---|
| OSS-only | OSS providers in this repo | In-cluster | teams starting quickly |
| AIMXS hosted | external AIMXS HTTPS endpoint | outbound to hosted AIMXS | central managed service model |
| AIMXS local | AIMXS in stack/library | no internet dependency | regulated/on-premises |


## Adaptive Identity Matrix System (AIMXS)

AIMXS is a runtime decision engine for AI workflows. It evaluates each request against policy, risk, and context, then returns allow/deny outcomes plus structured evidence for audit trails. In practice, it acts as the “governance brain” behind automated agent actions.

* Integration is through `ExtensionProvider` registration and provider contracts.
* Recommended boundary is HTTPS + mTLS (`MTLSAndBearerTokenSecret` for stricter paths).
* Entitlement and deny semantics are enforced in runtime policy flow.

NOTE: There are two systems, the OSS baseline system here is enforcing real policy decisions. Everything is the same between the baseline and AIMXS versions, except the decision kernels. 

### Baseline Features

* A minimal working policy engine path suitable for wiring and guardrail posture.
* Decisions: returns ALLOW or DENY
* Rules: minimal deny set + default allow (delete denied, prod approval gate)
* Grant token: returns a simple grant token string on ALLOW
* Built in audit with most recent 2000 events emitted to runtime logs (logs can be shipped to a log sink)
* durable *run metadata and payload snapshots* in Postgres
* Evidence provider in-memory provider (evidence persists only as long as that provider pod stays up, it is not a durable evidence store)

### AIMXS Features 

* Richer decision model at the contract boundary
* Allows decision values: ALLOW, DENY, CHALLENGE, DEFER.
* Contract surface explicitly requires outcomes be one of: ALLOW, DENY, DEFER.
* Includes explicit grant-token requirements for non-DENY decisions when enforcement is enabled.
* Handshake message schema with deterministic hashing requirements
* Explicit gate to enforce handshake validation
* Mandates determinism constraints

Policy stratification, grants and escalation as normative structure:
* policy bucket classification
* required grants (or digest)
* grant match result PASS/FAIL/NOT_REQUIRED
* evidence readiness gating
* escalation ladder identifiers, record references and timeboxes
* fail-closed behavior for unknown boundary classes

Deterministic evidence commitments requiring evidence hashing to commit to:
* proposal/state/decision
* provider_meta including policy_stratification
* adapter response subsets
* kernel_state continuity tokens when enabled
* config snapshots when present
* normalized evidence pointers

Explicit audit integration seam with optional audit sink interface 

Governance providers emit audit events through sink

Treats audit events as something that can be part of evidence requirements

AIMXS is structured around evidence artifacts and integrity commitments:
* providers produce an **EvidenceEnvelope** and compute an **evidence hash** that commits to structured content
* provides a deterministic **evidence bundle manifest generator** listing evidence files and sha256 digests
* includes a **retention policy shape** that is evidence-aware keyed by action/risk/boundary classes
* enumerates required evidence kinds (including audit events), with an "escalate on missing" boolean.
* produce evidence artifacts whose integrity is committed by hash
* manages retention and escalation based on completeness/readiness

AIMXS is designed to represent varied governance outcomes e.g. “not allowed but also not simply deny” workflows backed by evidence readiness and grant satisfaction gating.
* DEFER is a first-class outcome in the governance provider
* forces **DEFER only** when evidence is not ready, required grants are unmet or with an optional configured timeout. Otherwise DEFER becomes DENY.
* the governance provider uses gate evaluation and can enforce handshake validation
* returns ERROR if handshake validation fails, which the governance provider converts to DENY (unless timeout posture is DEFER)

## Quick Start (Local)

Prerequisites:

- Docker + kind
- kubectl
- Helm
- Go toolchain

Run baseline bring-up + smoke:

```bash
./platform/local/bin/verify-m0.sh
```

Run strict profile gates:

```bash
PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh
PROFILE=prod-full ./platform/ci/bin/run-gate-profile.sh
```

Run preflight QC only:

```bash
./platform/ci/bin/qc-preflight.sh
```

## Architecture At A Glance

- **Control plane**: provider registry controller + runtime orchestration API
- **Providers**: ProfileResolver, PolicyProvider, EvidenceProvider
- **Data plane state**: Postgres (CNPG)
- **Ops controls**: monitoring, admission policy, provenance lock checks, promotion gates

## Enterprise Adjacent

Current signal categories:

- security controls present and enforced
- strict staging/prod profile gates passing
- provenance lock checks strict-pass
- DR + rollback drills captured as machine-readable evidence
- governance boundary validation and private-release evidence path

## Comparison At A Glance

| Capability area | Typical API wrapper stack | Model-serving-only stack | Epydios AgentOps |
|---|---|---|---|
| Provider contract model | limited/informal | limited | explicit versioned contracts |
| Policy + evidence in runtime path | partial/manual | partial | built-in and test-gated |
| Tenant/project authz | often custom add-on | often custom add-on | built-in runtime checks |
| Admission + supply-chain controls | external bolt-on | external bolt-on | integrated verification path |
| AIMXS private boundary support | custom integration | custom integration | first-class external provider pattern |
| Promotion evidence (staging/prod strict) | inconsistent | inconsistent | profile-driven strict gate artifacts |

Related UI module (separate): [LINK WILL BE HERE WHEN AVAILABLE]
