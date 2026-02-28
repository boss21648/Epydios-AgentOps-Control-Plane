# Platform Test Manifests

This directory contains Kubernetes manifests used by local smoke and negative-test scripts.

- `provider-discovery-negative/` negative `ExtensionProvider` cases for controller status/error validation
- `provider-discovery-mtls/` positive mTLS `ExtensionProvider` cases for `MTLS` and `MTLSAndBearerTokenSecret`
- `provider-conformance-bearer/` bearer-auth `ExtensionProvider` conformance fixtures (`BearerTokenSecret` success + missing-secret failure)
- `provider-conformance-mtls/` mTLS provider conformance fixtures across provider types (`MTLS` + `MTLSAndBearerTokenSecret`)
- `provider-conformance/requests/` request/negative JSON fixtures used by M10 provider contract checks
- `phase4-secure-mtls/` secure auth fixtures for phase 04 policy/evidence flow (`MTLS` policy + `MTLSAndBearerTokenSecret` evidence)
- `kuberay-smoke/` minimal `RayCluster` API validation fixture for local phase 05 KubeRay smoke
- `kserve-smoke/` minimal `InferenceService` fixture for local phase 03 functional smoke (`Ready` + predict request)
- phase install/flow verification is handled by local scripts in `platform/local/bin/verify-phase-02-delivery-events.sh`, `platform/local/bin/verify-phase-03-kserve.sh`, `platform/local/bin/verify-phase-04-policy-evidence-kserve.sh`, and `platform/local/bin/verify-phase-05-kuberay.sh`
