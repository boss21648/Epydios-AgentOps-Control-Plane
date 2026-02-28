# AIMXS Release Evidence

This directory stores M10.2 release-evidence artifacts for private AIMXS publication
without importing AIMXS code into the OSS control-plane module graph.

## Inputs

- `private-release-inputs.vars`
  - private SDK release tag
  - provider release reference
  - either provider image digest fields or provider artifact path
  - release-notes reference

## Verifier

```bash
./platform/local/bin/verify-m10-aimxs-private-release.sh
```

The verifier checks:

1. AIMXS boundary contract (`verify-aimxs-boundary.sh`) still passes.
2. Private release inputs are non-placeholder and usable.
3. SDK/provider digest evidence can be computed/validated.
4. Latest staging strict gate log proves full gate + AIMXS boundary pass.

## Outputs

- `m10-2-private-release-evidence-<timestamp>.json`
- `m10-2-private-release-evidence-<timestamp>.json.sha256`
- `m10-2-private-release-evidence-latest.json`
- `m10-2-private-release-evidence-latest.json.sha256`
