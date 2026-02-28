# Argo CD Manifests

This directory contains `AppProject` and `Application` manifests for baseline platform phases.

## Production Overlay Application

- `apps/platform/epydios-control-plane-production.yaml`
  - tracks repository path `platform/overlays/production`
  - is the production-oriented deployment target for the control plane overlay pack

## Promotion Order

Promotion sequence is explicit and ordered:

1. dev
2. staging
3. prod

Machine-readable policy source:

- `promotion-order.yaml`

This policy is release-gate aligned:

- dev: `PROFILE=local-fast ./platform/ci/bin/run-gate-profile.sh`
- staging: `PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh`
- prod: `PROFILE=prod-full ./platform/ci/bin/run-gate-profile.sh`

## Notes

- Phase `00/01/02/03` applications are pinned to chart versions or Git commits.
- Phase `04` (`kuberay`) is present as an optional distributed-compute add-on.
- Apply `platform/base` (namespaces + `ExtensionProvider` CRD) before syncing provider-dependent services.
- Auto-sync is intentionally not enabled in these templates.
