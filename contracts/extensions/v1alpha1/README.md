# Extension Interfaces (`v1alpha1`)

This package freezes the first versioned plug-in boundary for:

- `PolicyProvider`
- `EvidenceProvider`
- `ProfileResolver`

These interfaces are the public OSS contracts that private modules (including AIMXS) can implement.

## Purpose

- Keep AIMXS out of the OSS build graph
- Preserve a stable integration target
- Enable OSS baseline providers and private providers to coexist

## Artifacts

- `provider-contracts.openapi.yaml`
  - HTTP/JSON request-response contracts for provider services
- `provider-registration-crd.yaml`
  - Kubernetes registration resource used by the control plane to discover/select providers

## Compatibility Rules

- `v1alpha1` is frozen for this repository bootstrap phase
- Additive changes only (new optional fields/endpoints)
- Breaking changes require a new API version directory
- Providers should ignore unknown request fields when possible
- Control plane must tolerate unknown provider capability strings

## Security Assumptions

- Provider endpoints are internal services or trusted external services
- mTLS is preferred for all provider traffic
- Bearer tokens or projected service account tokens may be used where mTLS is not yet available
- Provider responses are auditable and correlated via `requestId`

