# OSS Static Profile Resolver (Baseline)

This is a minimal OSS `ProfileResolver` provider implementation for the `v1alpha1` extension contract.

It is intentionally simple and deterministic:

- static default profile
- optional rule-based overrides by tenant/project/environment/task sensitivity
- no external dependencies required (Go stdlib HTTP server)

This provider is suitable for:

- early control-plane integration testing
- proving the `ExtensionProvider` registry/controller flow
- serving as a compatibility fallback when private providers are unavailable

## Run (after `go` toolchain is available)

```bash
go run ./cmd/profile-resolver-provider -config providers/profile/static-resolver/config.example.json
```

## Endpoints

- `GET /healthz`
- `GET /v1alpha1/capabilities`
- `POST /v1alpha1/profile-resolver/resolve`

