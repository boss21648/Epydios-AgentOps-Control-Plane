# Runtime SLO, SLI, and Error Budget Policy

Last updated: 2026-03-02

## Purpose

Define production operational objectives for the Epydios runtime API and provider orchestration path, and map those objectives to concrete alert rules.

## SLI Definitions

1. Runtime API availability SLI
   - Signal: `epydios_runtime_http_requests_total`
   - Good events: requests on `/v1alpha1/runtime/*` that do not return `5xx`
   - Bad events: requests on `/v1alpha1/runtime/*` that return `5xx`
2. Runtime API latency SLI
   - Signal: `epydios_runtime_http_request_duration_seconds`
   - Measurement: P95 on `/v1alpha1/runtime/*`
3. Runtime run-success SLI
   - Signal: `epydios_runtime_run_executions_total`
   - Good events: `outcome="completed"`
   - Counted failures: `outcome="failed"` (user-input `rejected` is tracked but excluded from success-ratio denominator)
4. Provider reliability SLI
   - Signal: `epydios_runtime_provider_calls_total`
   - Measurement: provider error ratio by `provider_type`

## SLO Targets

1. Runtime API availability
   - Objective: >= 99.9% monthly
2. Runtime API latency
   - Objective: P95 <= 1.5s over rolling 15m windows
3. Runtime run-success ratio
   - Objective: >= 98% over rolling 30m windows
4. Provider reliability
   - Objective: <= 10% error ratio per provider type over rolling 15m windows

## Error Budget Policy

1. Fast burn condition
   - Definition: >5% runtime API 5xx ratio over 5m
   - Action: page on-call immediately, start incident within 15 minutes
2. Slow burn condition
   - Definition: >1% runtime API 5xx ratio over 1h
   - Action: open operational incident ticket, mitigation plan same business day
3. Budget exhaustion handling
   - Freeze non-essential production changes
   - Prioritize reliability remediation until budget returns to target trajectory

## Alert Mapping

These rules are defined in:

- `platform/hardening/monitoring/prometheusrule-runtime-slo.yaml`

Alert set:

1. `EpydiosRuntimeAvailabilitySLOBurnFast` (critical)
2. `EpydiosRuntimeAvailabilitySLOBurnSlow` (warning)
3. `EpydiosRuntimeLatencySLIHigh` (warning)
4. `EpydiosRuntimeRunSuccessSLILow` (warning)
5. `EpydiosRuntimeProviderErrorRateHigh` (warning)
6. `EpydiosOrchestrationRuntimeUnavailable` (critical)
7. `EpydiosOrchestrationRuntimeCrashLooping` (warning)

## Ownership and Escalation

1. Platform engineering
   - Owns runtime metric schema and alert rules in repo.
2. SRE/operations
   - Owns Alertmanager routing, paging policy, and incident command.
3. Security
   - Owns severity policy and incident communications requirements for policy/evidence failures.

Primary ownership matrix for rollout policy remains:

- `docs/runbooks/monitoring-ownership-rollout.md`

## Evidence and Gate

M12.1 verifier:

- `platform/local/bin/verify-m12-slo-sli-pack.sh`

Full-mode CI gate wiring:

- `platform/ci/bin/pr-kind-phase03-gate.sh` with `RUN_M12_SLO_SLI_PACK=1`
