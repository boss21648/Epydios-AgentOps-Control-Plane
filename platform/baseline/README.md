# Platform Baseline (Initial Catalog)

This directory captures the initial bootstrap sequence and the component catalog for the `Epydios AgentOps Control Plane` Kubernetes baseline.

The baseline is intentionally split into ordered phases so the control plane can be stood up incrementally and debugged in layers.

## Current Strategy

- Build a stable OSS core first
- Keep private AIMXS integration behind extension provider contracts
- Pin versions through lockfiles (`../../provenance/*.lock.yaml`)
- Prefer Helm/OCI/chart/image pinning for deployments; source repos are for reference/patching

## Next Execution Work (after this scaffold)

1. Pin chart/image/CRD versions for phase 00-02
2. Create Argo CD Applications or Kustomize/Helm wrappers per component
3. Bring up a dev cluster and install `platform/base`
4. Install phase 00 foundation, then phase 01 observability/runtime
5. Add control plane core services and provider registry controller

