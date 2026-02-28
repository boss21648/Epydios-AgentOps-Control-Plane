# Postgres Backup/Restore Runbook (Draft)

Last updated: 2026-02-27

## Scope

Operational runbook for CloudNativePG backup/restore drills in pilot environments.

## Preconditions

1. CNPG operator is healthy in `cnpg-system`.
2. Cluster `epydios-postgres` is `Ready=True`.
3. Superuser/app secrets are present in `epydios-system`.

## Standard Drill

Run the automated drill:

```bash
./platform/local/bin/verify-m7-cnpg-backup-restore.sh
```

Expected result:
- marker row created
- logical backup generated
- source loss simulated
- restore DB recovered with marker row present

## Manual Commands (If Needed)

1. Check cluster readiness:
   - `kubectl -n epydios-system get cluster.postgresql.cnpg.io epydios-postgres -o yaml`
2. Identify primary pod:
   - `kubectl -n epydios-system get pod -l cnpg.io/cluster=epydios-postgres,cnpg.io/instanceRole=primary`
3. Execute SQL shell:
   - `kubectl -n epydios-system exec -it <primary-pod> -- psql -U postgres -d aios_core`

## Failure Handling

1. If backup generation fails:
   - validate pod disk pressure and CNPG pod logs
2. If restore validation fails:
   - inspect generated SQL dump integrity
   - re-run drill with `KEEP_DUMP_FILE=1` for forensic inspection

## Escalation

Escalate immediately if:
1. drill fails twice consecutively in the same environment
2. CNPG cluster is not recoverable to `Ready=True`
3. restore integrity checks fail for production-like data
