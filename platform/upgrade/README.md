# Upgrade Safety Policy

This directory contains upgrade-compatibility policy inputs used by local and CI upgrade drills.

- `compatibility-policy.yaml` defines explicit allowed N-1 -> N release paths.
- `compatibility-policy-aimxs-decision-api.yaml` defines network/API compatibility guardrails for the private AIMXS decision service integration boundary.

Current enforcement entrypoint:

- `platform/local/bin/verify-m7-upgrade-safety.sh`

The verifier fails early if `PREVIOUS_TAG -> CURRENT_TAG` is not listed in `allowed_upgrade_paths`.
