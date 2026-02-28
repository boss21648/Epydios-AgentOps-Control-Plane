# OSS Evidence Provider (Memory)

This provider implements the `EvidenceProvider` extension contract and stores evidence metadata in-memory for local development and smoke testing.

## Endpoints

- `/healthz`
- `/v1alpha1/capabilities`
- `/v1alpha1/evidence-provider/record`
- `/v1alpha1/evidence-provider/finalize-bundle`

## Notes

- Storage is in-memory and resets on pod restart.
- `record` returns deterministic `evidenceId`/`checksum` values derived from the request payload.
- `finalize-bundle` returns a synthetic manifest URI/checksum suitable for contract validation and local test flows.

