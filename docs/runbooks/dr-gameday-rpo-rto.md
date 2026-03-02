# DR Game Day: RPO and RTO Verification

Last updated: 2026-03-02

## Purpose

Define repeatable disaster-recovery game-day checks with explicit RPO/RTO thresholds and machine-readable evidence output.

## Verifier

- `platform/local/bin/verify-m12-dr-gameday.sh`

## Default Thresholds

1. `MAX_RPO_SECONDS=300`
2. `MAX_RTO_SECONDS=900`

These can be overridden per environment profile:

- `platform/ci/profiles/staging-full.env`
- `platform/ci/profiles/prod-full.env`

## Method

1. Seed marker row in source DB.
2. Create logical backup.
3. Simulate data loss in source DB.
4. Restore into restore DB.
5. Assert marker recovered.
6. Compute and enforce:
   - RPO proxy: `backup_completed_at - marker_inserted_at`
   - RTO: `restore_completed_at - restore_started_at`
7. Emit JSON evidence + SHA-256 digest.

## Evidence Output

Default path:

- `../EPYDIOS_AI_CONTROL_PLANE_NON_GITHUB/provenance/dr-gameday/`

Artifacts:

1. `m12-2-dr-gameday-<timestamp>.json`
2. `m12-2-dr-gameday-<timestamp>.json.sha256`
3. `m12-2-dr-gameday-latest.json`
4. `m12-2-dr-gameday-latest.json.sha256`

## Gate Wiring

- Full mode requires `RUN_M12_DR_GAMEDAY=1` in:
  - `platform/ci/bin/pr-kind-phase03-gate.sh`
  - `platform/ci/profiles/staging-full.env`
  - `platform/ci/profiles/prod-full.env`

## Example Run

```bash
MAX_RPO_SECONDS=300 MAX_RTO_SECONDS=900 ./platform/local/bin/verify-m12-dr-gameday.sh
```
