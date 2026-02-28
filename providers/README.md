# Providers (Planned)

Provider implementations are intentionally separated from the core control plane so AIMXS and OSS providers can share the same contract surface.

## Planned OSS Baseline Providers

- `policy/opa-adapter` (or equivalent) for baseline policy evaluation
- `evidence/basic-store` for structured evidence manifests and event records
- `profile/static-resolver` for deterministic profile resolution by tenant/environment

## Private Providers

- AIMXS providers should be delivered as separate images/repos and registered through `ExtensionProvider` resources.
- AIMXS slot boundary interfaces live in `../internal/aimxs/slot.go` and are intentionally OSS-only abstractions (no private code linkage).

## Contract Rule

All providers must implement the versioned contracts under `../contracts/extensions/`.
