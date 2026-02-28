# Data Manifests

This directory contains repository-owned data plane manifests used for local development and smoke testing.

- `cnpg-test-cluster/` local `CloudNativePG` cluster manifest and bootstrap secrets
- `cnpg-prod-cluster/` production-oriented `CloudNativePG` manifests (HA, storage sizing, `ExternalSecret`-managed credentials, scheduled backups)
- `postgres-smoketest/` simple SQL smoke test job against the CNPG cluster
- backup/restore drill entrypoint: `platform/local/bin/verify-m7-cnpg-backup-restore.sh`
- upgrade safety policy: `platform/upgrade/compatibility-policy.yaml`
