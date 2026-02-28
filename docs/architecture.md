# Architecture (Initial)

## Product Boundary

`Epydios AgentOps Control Plane` is an OSS control plane for AI/agent execution on Kubernetes. It is not a kernel, distro, or desktop operating system.

## Core Design Goals

- OSS baseline is fully deployable without AIMXS
- AIMXS can be added later as a private provider plug-in
- Versioned provider contracts remain stable once adopted by operators/tenants
- Dependency provenance and licensing are tracked from the beginning

## System Layers

1. **Platform Substrate (Kubernetes Add-ons)**
   - CloudNativePG, cert-manager, External Secrets, Gateway API
   - OTel Operator, Fluent Bit, KEDA
   - Argo Rollouts, Argo Events
   - KServe first, KubeRay later

2. **Control Plane Core (OSS)**
   - API server/controllers (extension registry + runtime orchestration service implemented)
   - provider registry and routing
   - policy/evidence/profile orchestration
   - tenant/project context and execution metadata

3. **Provider Interface Layer (Versioned)**
   - `PolicyProvider`
   - `EvidenceProvider`
   - `ProfileResolver`

4. **Provider Implementations**
   - OSS baseline providers (noop/OPA-backed/basic evidence store)
   - AIMXS private provider(s)

## AIMXS Integration Model

AIMXS stays outside the OSS build graph and integrates through the versioned provider contracts:

- register provider endpoint via `ExtensionProvider`
- advertise capabilities
- enforce authn/authz and mTLS at runtime
- return policy decisions/evidence/profile selections using the public contract

This allows:

- OSS distribution without private code
- commercial/private AIMXS licensing
- runtime replacement or fallback providers

## Contract Stability Rules (Initial)

- `v1alpha1` is frozen for initial implementation in this repo
- additive fields/endpoints only within `v1alpha1`
- breaking changes require `v1alpha2`
- providers must ignore unknown fields where safe

## Recommended Near-Term Build Plan

1. Implement provider registry CRD/controller wiring
2. Implement a minimal OSS `PolicyProvider` adapter (OPA passthrough)
3. Implement a minimal OSS `EvidenceProvider` (Postgres + object store manifest records)
4. Implement a simple `ProfileResolver` (static rules + tenant defaults)
5. Wire one end-to-end policy-evidence flow before adding AIMXS plugin
