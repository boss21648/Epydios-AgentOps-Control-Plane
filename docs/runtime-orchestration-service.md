# Runtime Orchestration Service (Step 1)

This service moves policy/evidence/profile execution flow out of ad-hoc scripts and into a persistent API service.

## Binary

- `cmd/control-plane-runtime`

## Persistence

- Backed by Postgres table `orchestration_runs`
- Automatically creates schema on startup

## Provider Selection

- Reads `ExtensionProvider` resources from the configured namespace
- Requires `status.conditions` `Ready=True` and `Probed=True`
- Applies `selection.enabled` and `selection.priority`
- Filters by required capability per stage:
  - `profile.resolve`
  - `policy.evaluate`
  - `evidence.record`

## API Endpoints

- `GET /healthz`
- `GET /metrics`
- `POST /v1alpha1/runtime/runs`
- `GET /v1alpha1/runtime/runs?limit=100&offset=0&status=...&policyDecision=...&tenantId=...&projectId=...&environment=...&providerId=...&retentionClass=...&search=...&createdAfter=...&createdBefore=...&includeExpired=true|false`
- `GET /v1alpha1/runtime/runs/export?format=jsonl|csv` (supports the same filters as list)
- `POST /v1alpha1/runtime/runs/retention/prune` (`dryRun`, `before`, `retentionClass`, `limit`)
- `GET /v1alpha1/runtime/runs/{runId}`
- `GET /v1alpha1/runtime/audit/events?limit=100&tenantId=...&projectId=...&providerId=...&decision=...&event=...`

## Runtime Metrics (M12.1)

Runtime exposes SLO/SLI metrics at `/metrics`:

- `epydios_runtime_http_requests_total` (`method`, `path`, `status_class`, `status_code`)
- `epydios_runtime_http_request_duration_seconds` (`method`, `path`)
- `epydios_runtime_run_executions_total` (`outcome`, `decision`)
- `epydios_runtime_run_execution_duration_seconds` (`outcome`, `decision`)
- `epydios_runtime_provider_calls_total` (`provider_type`, `operation`, `outcome`)
- `epydios_runtime_provider_call_duration_seconds` (`provider_type`, `operation`, `outcome`)

## Runtime API Authn/Authz + Tenancy + Audit (M9.1/M9.2/M9.3/M9.4)

- Disabled by default (`AUTHN_ENABLED=false`)
- When enabled:
  - requires `Authorization: Bearer <jwt>` on `/v1alpha1/runtime/runs*`
  - enforces create/list/read permissions by role mapping
  - supports OIDC/JWKS (`RS256`) and local shared-secret mode (`HS256`)
- Environment/flags:
  - `AUTHN_ENABLED`, `AUTHN_ISSUER`, `AUTHN_AUDIENCE`
  - `AUTHN_JWKS_URL`, `AUTHN_JWKS_CACHE_TTL`, `AUTHN_HS256_SECRET`
  - `AUTHN_ROLE_CLAIM`, `AUTHN_CLIENT_ID_CLAIM`
  - `AUTHN_TENANT_CLAIM`, `AUTHN_PROJECT_CLAIM`
  - `AUTHZ_CREATE_ROLES`, `AUTHZ_READ_ROLES`, `AUTHZ_ALLOWED_CLIENT_IDS`
  - `AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON` (OIDC role-to-permission translation matrix)
  - `AUTHZ_POLICY_MATRIX_JSON` (tenant/project allow/deny policy rules)
  - `AUTHZ_POLICY_MATRIX_REQUIRED` (require non-empty policy matrix when auth is enabled)
  - `AUTHZ_REQUIRE_POLICY_GRANT` (require policy grant token for non-`DENY` decisions before execution continues)
  - `AUTHZ_REQUIRE_AIMXS_ENTITLEMENT` (enable runtime entitlement checks for AIMXS policy-provider path)
  - `AUTHZ_AIMXS_PROVIDER_PREFIXES` (comma-separated provider name/providerId prefixes considered AIMXS)
  - `AUTHZ_AIMXS_ALLOWED_SKUS` (comma-separated allowed SKUs; optional)
  - `AUTHZ_AIMXS_REQUIRED_FEATURES` (comma-separated required feature flags; optional)
  - `AUTHZ_AIMXS_SKU_FEATURES_JSON` (JSON map: `sku -> required feature list`)
  - `AUTHZ_AIMXS_ENTITLEMENT_TOKEN_REQUIRED` (require entitlement token on AIMXS path; defaults true)
  - `POLICY_LIFECYCLE_ENABLED` (enable lifecycle checks on policy bundle metadata)
  - `POLICY_LIFECYCLE_MODE` (`observe` or `enforce`)
  - `POLICY_ALLOWED_IDS` (comma-separated allowed policy bundle IDs)
  - `POLICY_MIN_VERSION` (minimum accepted policy bundle version)
  - `POLICY_ROLLOUT_PERCENT` (stable rollout bucket allowlist, `0-100`)
  - `RETENTION_DEFAULT_CLASS` (default class when request omits `retentionClass`)
  - `RETENTION_POLICY_JSON` (JSON map of `retentionClass -> duration`, for example `{"short":"24h","standard":"168h","archive":"720h"}`)
- Scope enforcement:
  - create/read/list paths enforce tenant/project scope from JWT claims when scope claims are present
  - cross-tenant and cross-project access is denied
- RBAC policy matrix (M9.4):
  - role mappings translate IdP/OIDC roles to runtime permissions
  - policy rules apply allow/deny precedence with tenant/project selectors
  - deny rules override allow rules; missing allow rule denies access
- Structured audit:
  - emits JSON audit events to runtime logs for authn/authz decisions, policy matrix allow/deny, provider selection, policy decisions, and run outcome
  - exposes recent in-memory audit events via `GET /v1alpha1/runtime/audit/events` for operator UI reads (scoped by authz + tenant/project rules)
- Error mapping:
  - missing/invalid token -> `401 UNAUTHORIZED`
  - permission/client-id denial -> `403 FORBIDDEN`

## Policy Lifecycle Controls (M9.6)

- Runtime captures policy bundle metadata (`policyBundleId`, `policyBundleVersion`) from policy responses.
- Lifecycle policy can enforce:
  - approved policy IDs (`POLICY_ALLOWED_IDS`)
  - minimum version floor (`POLICY_MIN_VERSION`)
  - rollout window (`POLICY_ROLLOUT_PERCENT`)
- Modes:
  - `observe`: emit lifecycle violation audit events and continue execution
  - `enforce`: block run execution when lifecycle checks fail

## Retention Controls (M9.6)

- Runtime records `retentionClass` and computes `expiresAt` from `RETENTION_POLICY_JSON`.
- Unknown retention classes are rejected when retention policy map is configured.
- Operators can run prune checks (or deletion) via:
  - `POST /v1alpha1/runtime/runs/retention/prune`
  - `dryRun=true` returns candidate run IDs/count without deleting.

## Policy Grant Enforcement (AIMXS-Compatible)

- Optional strict mode (`AUTHZ_REQUIRE_POLICY_GRANT=true`) blocks execution when policy decision is non-`DENY` and no grant token is returned.
- Supported grant token fields from policy response:
  - `grantToken`
  - `grant_token`
  - `capabilityGrant`
  - `capability_grant`
  - `output.grantToken` / `output.grant_token` / `output.aimxsGrantToken`
- Runtime stores only:
  - `policyGrantTokenPresent`
  - `policyGrantTokenSha256`
- Raw grant token values are redacted from persisted `policyResponse` payloads.

## AIMXS Entitlement Enforcement (M10.6)

- Optional strict mode (`AUTHZ_REQUIRE_AIMXS_ENTITLEMENT=true`) applies only to policy providers whose name/providerId matches `AUTHZ_AIMXS_PROVIDER_PREFIXES`.
- Runtime reads entitlement inputs from `request.annotations` (`aimxsEntitlement.sku`, `aimxsEntitlement.token`, `aimxsEntitlement.features`, plus flat-key compatibility aliases).
- Runtime performs deny-first checks before policy provider call:
  - token required (when enabled)
  - SKU allowlist (`AUTHZ_AIMXS_ALLOWED_SKUS`)
  - required feature flags (`AUTHZ_AIMXS_REQUIRED_FEATURES` + `AUTHZ_AIMXS_SKU_FEATURES_JSON`)
- On entitlement failure, runtime emits a synthetic `DENY` policy result with explicit reason codes:
  - `AIMXS_ENTITLEMENT_TOKEN_REQUIRED`
  - `AIMXS_ENTITLEMENT_SKU_REQUIRED`
  - `AIMXS_ENTITLEMENT_SKU_NOT_ALLOWED`
  - `AIMXS_ENTITLEMENT_FEATURE_MISSING`
- Audit events:
  - `runtime.aimxs.entitlement.evaluate`
  - `runtime.aimxs.entitlement.allow`
  - `runtime.aimxs.entitlement.deny`

## Execution Flow

1. Resolve profile
2. Evaluate policy
3. Record evidence
4. Finalize evidence bundle
5. Persist stage transitions and outputs in Postgres

## Kubernetes Manifests

- `platform/system/controllers/orchestration-runtime/*`

## Local Verification Gate

- `platform/local/bin/verify-m5-runtime-orchestration.sh`
  - optional bootstrap (`RUN_BOOTSTRAP=1`) to ensure CNPG/Postgres substrate
  - optional image build/load (`RUN_IMAGE_PREP=1`)
  - validates `create/list/get` runtime APIs with both ALLOW and DENY flows
- `platform/local/bin/verify-m9-authn-authz.sh`
  - optional baseline bootstrap via M5 verifier
  - enables runtime authn/authz in-cluster
  - validates `401`, `403`, and role/client-id enforcement paths
- `platform/local/bin/verify-m9-authz-tenancy.sh`
  - optional baseline bootstrap via M5 verifier
  - validates tenant/project scope isolation and cross-tenant denial paths
  - validates runtime audit event emission for authz, provider selection, policy decision, and run completion
- `platform/local/bin/verify-m9-rbac-matrix.sh`
  - optional baseline bootstrap via M5 verifier
  - validates OIDC role mapping and tenant/project allow/deny policy matrix behavior
  - validates explicit deny-rule precedence and implicit no-allow denial paths
- `platform/local/bin/verify-m9-audit-read.sh`
  - optional baseline bootstrap via M5 verifier
  - validates authenticated `GET /v1alpha1/runtime/audit/events` reads
  - validates tenant/project scoped filtering and provider/decision/event query filters
  - validates invalid query handling (`INVALID_LIMIT`)
- `platform/local/bin/verify-m9-policy-lifecycle-and-run-query.sh`
  - optional baseline bootstrap via M5 verifier
  - validates policy lifecycle enforcement (`observe|enforce`)
  - validates run list filter/search semantics
  - validates CSV/JSONL export
  - validates retention prune dry-run behavior
- `platform/local/bin/verify-m10-policy-grant-enforcement.sh`
  - optional baseline bootstrap via M5 verifier
  - validates non-bypassable grant enforcement (`no token => no execution`) for non-`DENY` policy decisions
- `platform/local/bin/verify-m10-entitlement-deny.sh`
  - optional baseline bootstrap via M5 verifier
  - validates AIMXS entitlement deny paths (missing token, bad SKU, missing feature) and licensed ALLOW path
