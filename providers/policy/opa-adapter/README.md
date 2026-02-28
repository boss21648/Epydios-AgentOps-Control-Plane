# OSS Policy Provider (OPA Adapter)

This provider implements the `PolicyProvider` extension contract and delegates policy evaluation to an `OPA` HTTP API endpoint.

## Endpoints

- `/healthz` (checks adapter process + OPA health endpoint)
- `/v1alpha1/capabilities`
- `/v1alpha1/policy-provider/evaluate`
- `/v1alpha1/policy-provider/validate-bundle`

## Configuration

See `config.example.json`.

The adapter expects OPA to expose a decision endpoint that returns a JSON object in `result`, typically at:

- `/v1/data/epydios/policy/evaluate`

The OPA decision result should include a `decision` field (`ALLOW|DENY|CHALLENGE|DEFER`) or an `allow` boolean. Optional fields like `grantToken` (or `output.grantToken`), `reasons`, `obligations`, `policyBundle`, and `output` are passed through when present.
