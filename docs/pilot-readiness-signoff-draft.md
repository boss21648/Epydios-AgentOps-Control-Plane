# Pilot Readiness Sign-off (Draft)

Last updated: 2026-03-01  
Status: Ready for Approval (evidence complete, approvals pending)

## Scope

This draft defines the pilot sign-off package for the Epydios AgentOps Control Plane.
It is the human-facing companion to `docs/pilot-readiness-signoff-draft.json`.

## Required Evidence Checklist

1. Full gate strict pass (M8.1 baseline)
   - Command: `GATE_MODE=full ./platform/ci/bin/pr-kind-phase03-gate.sh`
   - Must include: M7 integration + backup/restore + upgrade safety, hardening baseline, AIMXS boundary, strict provenance.
2. Monitoring/alert operational pass (M8.4)
   - Commands:
     - `./platform/local/bin/bootstrap-monitoring-stack.sh`
     - `./platform/local/bin/verify-monitoring-alerts.sh`
     - `REQUIRE_MONITORING_CRDS=1 RUN_MONITORING_ALERT_SMOKE=1 AUTO_INSTALL_MONITORING_STACK=0 ./platform/local/bin/verify-prod-hardening-baseline.sh`
   - Must include: ServiceMonitor and PrometheusRule loaded, synthetic alert firing observable.
   - Status: `pass` (local validation complete; staging/prod ownership still pending).
3. Security hardening pass (M8.3 baseline)
   - Command: `./platform/local/bin/verify-prod-hardening-baseline.sh`
   - Must include: NetworkPolicies applied, rotation checks passing with mTLS references in place.
4. Reliability drill pass (M8.5)
   - Commands:
     - `./platform/local/bin/verify-m7-integration.sh`
     - `./platform/local/bin/verify-m7-cnpg-backup-restore.sh`
     - `./platform/local/bin/verify-m7-upgrade-safety.sh`
5. AIMXS external boundary pass (M8.6 partial)
   - Command: `./platform/local/bin/verify-aimxs-boundary.sh`
   - Must include: HTTPS/auth constraints, slot-only contract use, no direct module leakage.
6. AIMXS private release evidence pass (M10.2)
   - Commands:
     - `./platform/local/bin/verify-m10-aimxs-private-release.sh`
     - `PROFILE=staging-full ./platform/ci/bin/run-gate-profile.sh`
   - Must include: private SDK/provider digest evidence plus strict staging profile pass.
   - Status: `pass` (artifact-mode private release evidence + staging strict proof archived).
7. Real tag release evidence pass (M8.2 / M11 release closure)
   - Command: `.github/workflows/release-images-ghcr.yml` on real tag (`v0.1.0`)
   - Must include: release digest artifacts, lockfile sync artifact, ingest + strict lock verification.
   - Status: `pass` (artifacts archived under `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/release-image-digests/`, `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/release-images-lockfile-sync/`, and `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/releases/20260301T181757Z/`).

## Draft SLOs (Pilot)

1. Control-plane API availability: `99.5%` monthly for runtime API endpoints.
2. Policy/evidence execution success: `>= 99%` successful run completions excluding intentional DENY decisions.
3. Decision latency p95: `<= 2.5s` for end-to-end policy+evidence path on baseline load.
4. MTTD for controller unavailability: `<= 5m` with monitoring stack enabled.
5. Data protection: verified backup/restore drill completed at least once per release candidate.

## Runbook Set (Draft)

1. Incident triage: `docs/runbooks/incident-triage.md`
2. Postgres backup/restore: `docs/runbooks/postgres-backup-restore.md`
3. AIMXS boundary and auth contract: `docs/aimxs-plugin-slot.md`
4. Monitoring ownership and rollout policy: `docs/runbooks/monitoring-ownership-rollout.md`
5. AIMXS private SDK publication process: `docs/runbooks/aimxs-private-sdk-publication.md`

## Go/No-Go Checklist (Draft)

1. All required evidence items are marked `pass`.
2. No open `critical` severity risk in pilot scope.
3. Provenance strict checks pass with no unresolved lockfile blockers.
4. License posture remains permissive-only for shipped dependencies.
5. Monitoring and alerting are active in target pilot cluster.

## Open Items Before Final Sign-off

1. Formal approvals from Engineering, Security, Operations, and Product owners.
2. Monitoring ownership adoption sign-off in target staging/prod environments (if operated by separate teams).
