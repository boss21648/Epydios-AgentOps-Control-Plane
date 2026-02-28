# Admission Hardening

This pack adds cluster admission controls for production supply-chain hygiene:

- immutable digest enforcement (`image@sha256:...`) using Kubernetes `ValidatingAdmissionPolicy`
- optional signed-image verification for `ghcr.io/epydios/*` via Kyverno (`../admission-kyverno`)

## Apply digest enforcement

```bash
kubectl apply -k platform/hardening/admission
```

Label namespaces you want enforced:

```bash
kubectl label namespace epydios-system epydios.ai/admission-enforced=true --overwrite
```

## Apply signed-image enforcement (Kyverno required)

```bash
kubectl apply -k platform/hardening/admission-kyverno
```

Kyverno CRDs/controllers must already be installed before applying `admission-kyverno`.
