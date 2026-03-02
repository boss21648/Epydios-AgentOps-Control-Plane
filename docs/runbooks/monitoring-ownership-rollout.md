# Monitoring Ownership And Rollout

Last updated: 2026-02-27

## Purpose

Define who owns monitoring in each environment and how monitoring requirements are enforced through gate profiles.

SLO/SLI objectives and error-budget policy are defined in:

- `docs/runbooks/slo-sli-error-budget.md`

## Ownership Matrix

1. Platform engineering
   - Owns repository-managed rules and monitors:
     - `platform/hardening/monitoring/*`
   - Owns monitor/rule schema and CI profile defaults.
2. SRE/operations
   - Owns monitoring stack lifecycle in staging/prod:
     - Prometheus and Alertmanager deployment
     - alert routing destinations and silences policy
   - Owns cluster-level run execution and incident response.
3. Security
   - Owns alert severity policy and escalation requirements.
4. Product/on-call lead
   - Owns pilot go/no-go decision using sign-off evidence.

## Environment Policy

1. Local development
   - Monitoring stack may be auto-installed for smoke work:
     - `AUTO_INSTALL_MONITORING_STACK=1` is allowed.
   - Intended command:
     - `./platform/local/bin/verify-monitoring-alerts.sh`
2. Staging
   - Monitoring stack must already exist.
   - Auto-install in gate is forbidden:
     - `AUTO_INSTALL_MONITORING_STACK=0`.
   - Monitoring CRDs are required:
     - `REQUIRE_MONITORING_CRDS=1`.
   - Alert path smoke is required:
     - `RUN_MONITORING_ALERT_SMOKE=1`.
3. Production
   - Same policy as staging.
   - Any temporary bypass requires explicit incident record and follow-up action item.

## CI Gate Profiles

Profiles are versioned under `platform/ci/profiles/` and run through:

- `platform/ci/bin/run-gate-profile.sh`

Available profiles:

1. `local-fast`
2. `staging-full`
3. `prod-full`

Examples:

```bash
PROFILE=local-fast ./platform/ci/bin/run-gate-profile.sh
PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh
PROFILE=prod-full ./platform/ci/bin/run-gate-profile.sh
```

## Rollout Checklist

1. Confirm monitoring stack ownership handoff (Platform -> SRE) is documented for target cluster.
2. Run `staging-full` profile and archive output in release evidence.
3. Validate alert routing path with synthetic smoke alert.
4. Ensure `prod-full` profile is available in runbook and dry-run on pre-prod before promotion.

## Adoption Sign-off Record

Status: COMPLETE (2026-03-01)

Evidence:

1. Staging strict profile proof:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/staging-full-gate-20260301T183622Z.log`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/staging-full-gate-20260301T183622Z.log.sha256`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/staging-full-gate-20260301T183622Z.log.proof.json`
2. Prod strict profile proof:
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/prod-full-gate-20260301T184620Z.log`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/prod-full-gate-20260301T184620Z.log.sha256`
   - `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/promotion/prod-full-gate-20260301T184620Z.log.proof.json`

Ownership confirmation:

1. Platform engineering: approved.
2. Operations/SRE: approved.
3. Security: approved.
4. Product/on-call: approved.
