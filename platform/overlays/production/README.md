# Production Overlay Pack

This overlay composes production-oriented defaults on top of the baseline control-plane manifests:

- runtime API auth enabled (`AUTHN_ENABLED=true`)
- runtime policy grant enforcement enabled (`AUTHZ_REQUIRE_POLICY_GRANT=true`)
- HA replicas for runtime and controller
- controller leader election enabled
- runtime Gateway API `HTTPRoute`
- production CNPG cluster manifest set (3 instances, larger storage, scheduled backup)
- hardening expansion:
  - ingress policies for runtime/providers
  - runtime egress policy (providers + Postgres + DNS + HTTPS endpoints)
  - admission policy for immutable digest image references (namespace-scoped)
  - runtime ServiceMonitor + PrometheusRule
- production image refs pinned to immutable digests for runtime/controller/providers

## Apply

```bash
kubectl apply -k platform/overlays/production
```

## Required Customization Before Production

1. Edit `runtime-auth-config.yaml` issuer/audience/JWKS URL, client IDs, and role/policy JSON to match your IdP and tenant model.
2. Configure your External Secrets backend (`ClusterSecretStore` named `epydios-platform-secrets`) and update remote references in:
   - `../../data/cnpg-prod-cluster/postgres-app-secret.yaml`
   - `../../data/cnpg-prod-cluster/postgres-superuser-secret.yaml`
   - `../../data/cnpg-prod-cluster/postgres-backup-s3-secret.yaml`
3. Update CNPG object-store settings in `../../data/cnpg-prod-cluster/cluster.yaml` (`destinationPath`, `endpointURL`, and retention policy).
4. Update runtime hostnames/parent gateway in `runtime-httproute.yaml`.
5. If your environment uses non-RFC1918 node addressing, tighten or adjust ingress policy CIDRs accordingly.
6. Install Kyverno before applying signed-image policy pack: `kubectl apply -k platform/hardening/admission-kyverno`.
7. Ensure selected policy providers return a short-lived grant token for non-`DENY` decisions (`grantToken` or `output.aimxsGrantToken`) or runtime execution will be blocked.
