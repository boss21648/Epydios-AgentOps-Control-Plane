# AIMXS Plug-in Slot (External Boundary)

This document codifies the boundary: AIMXS remains private and external to the OSS build graph.

## Design Rule

- OSS control plane exposes versioned provider contracts and `ExtensionProvider` registration.
- AIMXS runs as separate image(s)/repo(s), reachable via HTTPS endpoints.
- OSS must not import AIMXS code directly.
- Deployment modes stay on one contract surface:
  - OSS-only (`platform/modes/oss-only`)
  - AIMXS hosted HTTPS (`platform/modes/aimxs-hosted`)
  - AIMXS customer-hosted local/on-prem (`platform/modes/aimxs-customer-hosted`)

## Slot Interface

The OSS slot boundary is defined in:

- `internal/aimxs/slot.go`

This package defines:

- `SlotResolver` for capability-to-provider resolution
- `SlotRegistry` for external provider registration lifecycle
- `Registration` and endpoint auth shape (`None`, `BearerTokenSecret`, `MTLS`, `MTLSAndBearerTokenSecret`)

## Endpoint Security Expectations

- Prefer `MTLS` or `MTLSAndBearerTokenSecret` for AIMXS providers.
- Use HTTPS endpoint URLs for all mTLS modes.
- Keep AIMXS credentials/material in Kubernetes secrets referenced by `ExtensionProvider` auth fields.

## Local Development Mode (Non-Production)

- A local bootstrap path is allowed before private AIMXS is deployed:
  - `examples/aimxs/extensionprovider-policy-local-dev.yaml`
- This dev profile is intentionally `auth.mode=None` and `selection.enabled=false` by default.
- Use it only to validate contract compatibility and routing behavior in local clusters.
- Staging/prod must switch to HTTPS with `MTLS` or `MTLSAndBearerTokenSecret`.

## Deployment Mode Profiles

- Mode manifests are under `platform/modes/`.
- `oss-only` routes to OSS providers and keeps AIMXS out of the execution path.
- `aimxs-hosted` routes to hosted AIMXS endpoint over secure auth.
- `aimxs-customer-hosted` routes to customer-local AIMXS endpoint over secure auth, so policy execution does not require external data egress.

## Operational Contract

- AIMXS providers advertise capabilities through `/v1alpha1/capabilities`.
- Health endpoint defaults to `/healthz`.
- Contract compatibility remains tied to `contracts/extensions/v1alpha1`.
- Decision API compatibility policy is tracked in:
  - `platform/upgrade/compatibility-policy-aimxs-decision-api.yaml`
- For non-`DENY` decisions, AIMXS-compatible policy providers should return a grant token (`grantToken` or `output.aimxsGrantToken`) so runtime can enforce non-bypassable execution.
- Runtime can enforce entitlement/SKU boundary for AIMXS provider paths (`AUTHZ_REQUIRE_AIMXS_ENTITLEMENT=true`) before policy provider invocation.
- Entitlement policy is configured via runtime env:
  - `AUTHZ_AIMXS_PROVIDER_PREFIXES`
  - `AUTHZ_AIMXS_ALLOWED_SKUS`
  - `AUTHZ_AIMXS_REQUIRED_FEATURES`
  - `AUTHZ_AIMXS_SKU_FEATURES_JSON`
  - `AUTHZ_AIMXS_ENTITLEMENT_TOKEN_REQUIRED`

## Conformance and Failure Handling

- Conformance checks should prove:
  - provider probe success updates `ExtensionProvider.status.conditions` to `Ready=True` and `Probed=True`
  - endpoint URL is HTTPS and auth mode is `MTLS` or `MTLSAndBearerTokenSecret`
  - AIMXS is only referenced through `internal/aimxs/slot.go` interfaces
- Failure-handling behavior must stay observable at the CR status boundary:
  - endpoint/network/auth failures must surface as `Ready=False` / `Probed=False`
  - capability or provider-type mismatch must surface as probe failure with explicit status message
  - missing bearer or mTLS secret material must fail probe and never silently downgrade auth mode
- Local boundary verification is provided by:
  - `platform/local/bin/verify-aimxs-boundary.sh`
  - `platform/local/bin/verify-m10-policy-grant-enforcement.sh`
  - `platform/local/bin/verify-m10-entitlement-deny.sh`
  - `platform/local/bin/verify-m10-deployment-modes.sh`
  - `platform/local/bin/verify-m10-no-egress-local-aimxs.sh`
