# Incident Triage Runbook (Draft)

Last updated: 2026-02-27

## Scope

Use this runbook for control-plane incidents in pilot scope:
- runtime API failures
- provider discovery failures
- policy/evidence execution failures
- sustained crash loops in controller/provider pods

## Detection Signals

1. Alert: `EpydiosExtensionProviderRegistryControllerUnavailable`
2. Alert: `EpydiosControlPlaneProviderCrashLooping`
3. Runtime API error spikes (`5xx`) on orchestration runtime

## Triage Steps

1. Confirm cluster and namespaces:
   - `kubectl get nodes`
   - `kubectl get ns`
2. Check control-plane deployments:
   - `kubectl -n epydios-system get deploy,pods`
3. Check provider registry status:
   - `kubectl -n epydios-system get extensionprovider`
4. Inspect recent logs:
   - `kubectl -n epydios-system logs deployment/extension-provider-registry-controller --tail=200`
   - `kubectl -n epydios-system logs deployment/orchestration-runtime --tail=200`
5. Validate policy/evidence endpoints:
   - `kubectl -n epydios-system get svc epydios-oss-policy-provider epydios-oss-evidence-provider`

## Fast Mitigations

1. Restart unhealthy deployment:
   - `kubectl -n epydios-system rollout restart deployment/<name>`
2. Reconcile manifests:
   - `kubectl apply -k platform/system`
   - `kubectl apply -k platform/providers/oss-policy-opa`
   - `kubectl apply -k platform/providers/oss-evidence-memory`
3. Re-run critical checks:
   - `./platform/local/bin/verify-phase-04-policy-evidence-kserve.sh`
   - `./platform/local/bin/verify-m5-runtime-orchestration.sh`

## Escalation Criteria

Escalate to engineering lead immediately if:
1. controller unavailability persists > 15 minutes
2. backup/restore drill is failing
3. upgrade safety gate fails on release candidate
