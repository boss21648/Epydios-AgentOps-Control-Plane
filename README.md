# Epydios AgentOps Control Plane

**Policy-driven control plane for AI and agent workflows on Kubernetes.**

AgentOps Desktop is an open source control plane for governing agent actions with enforceable policy and auditable evidence. It evaluates each agent action against a policy provider, selects the right profile and extensions for the context, and records a structured evidence trail. Kubernetes-native, fast and composable, it provides a clean provider interface so you can swap policy engines, evidence stores and organization-specific decision logic without rewriting your runtime.

## Overview
Profile Provider = “What context/profile should we apply?”
- Looks at your request fields (tenant, project, environment, sensitivity, etc.)

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
| private boundary support (CONTACT US) | custom integration | custom integration | first-class external provider pattern |
| Promotion evidence (staging/prod strict) | inconsistent | inconsistent | profile-driven strict gate artifacts |

Related UI module: separate repository (to be announced).

## Community

- Contributing: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`
- Trademark policy: `TRADEMARK.md`
- Third-party notices: `THIRD_PARTY_NOTICES.md`
