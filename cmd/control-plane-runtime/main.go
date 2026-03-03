package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	corev1 "k8s.io/api/core/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	cpruntime "github.com/Epydios/Epydios-AgentOps-Desktop/internal/runtime"
)

type Config struct {
	ListenAddr          string
	Namespace           string
	PostgresDSN         string
	PostgresHost        string
	PostgresPort        int
	PostgresDB          string
	PostgresUser        string
	PostgresPassword    string
	PostgresSSLMode     string
	ProfileMinPriority  int64
	PolicyMinPriority   int64
	EvidenceMinPriority int64

	AuthEnabled                       bool
	AuthIssuer                        string
	AuthAudience                      string
	AuthJWKSURL                       string
	AuthHS256Secret                   string
	AuthJWKSCacheTTL                  time.Duration
	AuthRoleClaim                     string
	AuthClientIDClaim                 string
	AuthTenantClaim                   string
	AuthProjectClaim                  string
	AuthCreateRoles                   string
	AuthReadRoles                     string
	AuthAllowedClientIDs              string
	AuthRoleMappingsJSON              string
	AuthPolicyMatrixJSON              string
	AuthRequirePolicyMatrix           bool
	AuthRequirePolicyGrant            bool
	AuthRequireAIMXSEntitlement       bool
	AuthAIMXSProviderPrefixes         string
	AuthAIMXSAllowedSKUs              string
	AuthAIMXSRequiredFeatures         string
	AuthAIMXSSKUFeaturesJSON          string
	AuthAIMXSEntitlementTokenRequired bool
	PolicyLifecycleEnabled            bool
	PolicyLifecycleMode               string
	PolicyAllowedIDs                  string
	PolicyMinVersion                  string
	PolicyRolloutPercent              int
	RetentionDefaultClass             string
	RetentionPolicyJSON               string
}

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		log.Fatalf("runtime service failed: %v", err)
	}
}

func parseFlags() Config {
	cfg := Config{
		ListenAddr:       envOrDefault("LISTEN_ADDR", ":8080"),
		Namespace:        envOrDefault("NAMESPACE", "epydios-system"),
		PostgresDSN:      stringsOrDefault(os.Getenv("POSTGRES_DSN"), os.Getenv("EPYDIOS_POSTGRES_DSN")),
		PostgresHost:     envOrDefault("POSTGRES_HOST", "epydios-postgres-rw"),
		PostgresPort:     envIntOrDefault("POSTGRES_PORT", 5432),
		PostgresDB:       envOrDefault("POSTGRES_DB", "aios_core"),
		PostgresUser:     envOrDefault("POSTGRES_USER", ""),
		PostgresPassword: envOrDefault("POSTGRES_PASSWORD", ""),
		PostgresSSLMode:  envOrDefault("POSTGRES_SSLMODE", "disable"),

		AuthEnabled:                       envBoolOrDefault("AUTHN_ENABLED", false),
		AuthIssuer:                        envOrDefault("AUTHN_ISSUER", ""),
		AuthAudience:                      envOrDefault("AUTHN_AUDIENCE", ""),
		AuthJWKSURL:                       envOrDefault("AUTHN_JWKS_URL", ""),
		AuthHS256Secret:                   envOrDefault("AUTHN_HS256_SECRET", ""),
		AuthJWKSCacheTTL:                  envDurationOrDefault("AUTHN_JWKS_CACHE_TTL", 5*time.Minute),
		AuthRoleClaim:                     envOrDefault("AUTHN_ROLE_CLAIM", "roles"),
		AuthClientIDClaim:                 envOrDefault("AUTHN_CLIENT_ID_CLAIM", "client_id"),
		AuthTenantClaim:                   envOrDefault("AUTHN_TENANT_CLAIM", "tenant_id"),
		AuthProjectClaim:                  envOrDefault("AUTHN_PROJECT_CLAIM", "project_id"),
		AuthCreateRoles:                   envOrDefault("AUTHZ_CREATE_ROLES", "runtime.admin,runtime.run.create"),
		AuthReadRoles:                     envOrDefault("AUTHZ_READ_ROLES", "runtime.admin,runtime.run.read"),
		AuthAllowedClientIDs:              envOrDefault("AUTHZ_ALLOWED_CLIENT_IDS", ""),
		AuthRoleMappingsJSON:              envOrDefault("AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON", ""),
		AuthPolicyMatrixJSON:              envOrDefault("AUTHZ_POLICY_MATRIX_JSON", ""),
		AuthRequirePolicyMatrix:           envBoolOrDefault("AUTHZ_POLICY_MATRIX_REQUIRED", false),
		AuthRequirePolicyGrant:            envBoolOrDefault("AUTHZ_REQUIRE_POLICY_GRANT", false),
		AuthRequireAIMXSEntitlement:       envBoolOrDefault("AUTHZ_REQUIRE_AIMXS_ENTITLEMENT", false),
		AuthAIMXSProviderPrefixes:         envOrDefault("AUTHZ_AIMXS_PROVIDER_PREFIXES", "aimxs-"),
		AuthAIMXSAllowedSKUs:              envOrDefault("AUTHZ_AIMXS_ALLOWED_SKUS", ""),
		AuthAIMXSRequiredFeatures:         envOrDefault("AUTHZ_AIMXS_REQUIRED_FEATURES", ""),
		AuthAIMXSSKUFeaturesJSON:          envOrDefault("AUTHZ_AIMXS_SKU_FEATURES_JSON", ""),
		AuthAIMXSEntitlementTokenRequired: envBoolOrDefault("AUTHZ_AIMXS_ENTITLEMENT_TOKEN_REQUIRED", true),
		PolicyLifecycleEnabled:            envBoolOrDefault("POLICY_LIFECYCLE_ENABLED", false),
		PolicyLifecycleMode:               envOrDefault("POLICY_LIFECYCLE_MODE", "observe"),
		PolicyAllowedIDs:                  envOrDefault("POLICY_ALLOWED_IDS", ""),
		PolicyMinVersion:                  envOrDefault("POLICY_MIN_VERSION", ""),
		PolicyRolloutPercent:              envIntOrDefault("POLICY_ROLLOUT_PERCENT", 100),
		RetentionDefaultClass:             envOrDefault("RETENTION_DEFAULT_CLASS", "standard"),
		RetentionPolicyJSON:               envOrDefault("RETENTION_POLICY_JSON", ""),
	}

	flag.StringVar(&cfg.ListenAddr, "listen", cfg.ListenAddr, "HTTP listen address")
	flag.StringVar(&cfg.Namespace, "namespace", cfg.Namespace, "Namespace containing ExtensionProvider resources")
	flag.StringVar(&cfg.PostgresDSN, "postgres-dsn", cfg.PostgresDSN, "Postgres DSN override (optional)")
	flag.StringVar(&cfg.PostgresHost, "postgres-host", cfg.PostgresHost, "Postgres host")
	flag.IntVar(&cfg.PostgresPort, "postgres-port", cfg.PostgresPort, "Postgres port")
	flag.StringVar(&cfg.PostgresDB, "postgres-db", cfg.PostgresDB, "Postgres database name")
	flag.StringVar(&cfg.PostgresUser, "postgres-user", cfg.PostgresUser, "Postgres username")
	flag.StringVar(&cfg.PostgresPassword, "postgres-password", cfg.PostgresPassword, "Postgres password")
	flag.StringVar(&cfg.PostgresSSLMode, "postgres-sslmode", cfg.PostgresSSLMode, "Postgres sslmode")
	flag.Int64Var(&cfg.ProfileMinPriority, "profile-min-priority", 0, "Minimum priority for ProfileResolver providers")
	flag.Int64Var(&cfg.PolicyMinPriority, "policy-min-priority", 0, "Minimum priority for PolicyProvider providers")
	flag.Int64Var(&cfg.EvidenceMinPriority, "evidence-min-priority", 0, "Minimum priority for EvidenceProvider providers")
	flag.BoolVar(&cfg.AuthEnabled, "authn-enabled", cfg.AuthEnabled, "Enable runtime API OIDC/JWT authn/authz checks")
	flag.StringVar(&cfg.AuthIssuer, "authn-issuer", cfg.AuthIssuer, "Required JWT issuer claim (optional)")
	flag.StringVar(&cfg.AuthAudience, "authn-audience", cfg.AuthAudience, "Required JWT audience claim (optional)")
	flag.StringVar(&cfg.AuthJWKSURL, "authn-jwks-url", cfg.AuthJWKSURL, "OIDC JWKS URL for RS256 verification (optional)")
	flag.StringVar(&cfg.AuthHS256Secret, "authn-hs256-secret", cfg.AuthHS256Secret, "HS256 shared secret for local/dev JWT verification (optional)")
	flag.DurationVar(&cfg.AuthJWKSCacheTTL, "authn-jwks-cache-ttl", cfg.AuthJWKSCacheTTL, "JWKS cache TTL")
	flag.StringVar(&cfg.AuthRoleClaim, "authn-role-claim", cfg.AuthRoleClaim, "JWT claim used for role extraction")
	flag.StringVar(&cfg.AuthClientIDClaim, "authn-client-id-claim", cfg.AuthClientIDClaim, "JWT claim used for client_id extraction")
	flag.StringVar(&cfg.AuthTenantClaim, "authn-tenant-claim", cfg.AuthTenantClaim, "JWT claim used for tenant scope extraction")
	flag.StringVar(&cfg.AuthProjectClaim, "authn-project-claim", cfg.AuthProjectClaim, "JWT claim used for project scope extraction")
	flag.StringVar(&cfg.AuthCreateRoles, "authz-create-roles", cfg.AuthCreateRoles, "Comma-separated roles allowed for create run")
	flag.StringVar(&cfg.AuthReadRoles, "authz-read-roles", cfg.AuthReadRoles, "Comma-separated roles allowed for read/list run")
	flag.StringVar(&cfg.AuthAllowedClientIDs, "authz-allowed-client-ids", cfg.AuthAllowedClientIDs, "Comma-separated allowed client IDs (optional)")
	flag.StringVar(&cfg.AuthRoleMappingsJSON, "authz-role-permission-mappings-json", cfg.AuthRoleMappingsJSON, "JSON role->permissions mapping for OIDC role translation")
	flag.StringVar(&cfg.AuthPolicyMatrixJSON, "authz-policy-matrix-json", cfg.AuthPolicyMatrixJSON, "JSON authz policy matrix (allow/deny rules with tenant/project selectors)")
	flag.BoolVar(&cfg.AuthRequirePolicyMatrix, "authz-policy-matrix-required", cfg.AuthRequirePolicyMatrix, "Require non-empty authz policy matrix when auth is enabled")
	flag.BoolVar(&cfg.AuthRequirePolicyGrant, "authz-require-policy-grant", cfg.AuthRequirePolicyGrant, "Require policy grant token for non-DENY decisions before execution continues")
	flag.BoolVar(&cfg.AuthRequireAIMXSEntitlement, "authz-require-aimxs-entitlement", cfg.AuthRequireAIMXSEntitlement, "Require AIMXS entitlement validation for configured AIMXS policy providers")
	flag.StringVar(&cfg.AuthAIMXSProviderPrefixes, "authz-aimxs-provider-prefixes", cfg.AuthAIMXSProviderPrefixes, "Comma-separated provider name/providerId prefixes treated as AIMXS policy providers")
	flag.StringVar(&cfg.AuthAIMXSAllowedSKUs, "authz-aimxs-allowed-skus", cfg.AuthAIMXSAllowedSKUs, "Comma-separated allowed AIMXS SKUs (optional)")
	flag.StringVar(&cfg.AuthAIMXSRequiredFeatures, "authz-aimxs-required-features", cfg.AuthAIMXSRequiredFeatures, "Comma-separated required AIMXS feature flags (optional)")
	flag.StringVar(&cfg.AuthAIMXSSKUFeaturesJSON, "authz-aimxs-sku-features-json", cfg.AuthAIMXSSKUFeaturesJSON, "JSON map of sku -> list of required features")
	flag.BoolVar(&cfg.AuthAIMXSEntitlementTokenRequired, "authz-aimxs-entitlement-token-required", cfg.AuthAIMXSEntitlementTokenRequired, "Require entitlement token for AIMXS provider path")
	flag.BoolVar(&cfg.PolicyLifecycleEnabled, "policy-lifecycle-enabled", cfg.PolicyLifecycleEnabled, "Enable policy bundle lifecycle controls")
	flag.StringVar(&cfg.PolicyLifecycleMode, "policy-lifecycle-mode", cfg.PolicyLifecycleMode, "Policy lifecycle mode: observe|enforce")
	flag.StringVar(&cfg.PolicyAllowedIDs, "policy-allowed-ids", cfg.PolicyAllowedIDs, "Comma-separated allowed policy bundle IDs")
	flag.StringVar(&cfg.PolicyMinVersion, "policy-min-version", cfg.PolicyMinVersion, "Minimum accepted policy bundle version")
	flag.IntVar(&cfg.PolicyRolloutPercent, "policy-rollout-percent", cfg.PolicyRolloutPercent, "Policy bundle rollout percentage (0-100)")
	flag.StringVar(&cfg.RetentionDefaultClass, "retention-default-class", cfg.RetentionDefaultClass, "Default retention class for runs")
	flag.StringVar(&cfg.RetentionPolicyJSON, "retention-policy-json", cfg.RetentionPolicyJSON, "JSON map of retentionClass to duration (for example {\"standard\":\"168h\",\"short\":\"24h\"})")
	flag.Parse()

	return cfg
}

func run(cfg Config) error {
	dsn, err := postgresDSN(cfg)
	if err != nil {
		return err
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return fmt.Errorf("open postgres: %w", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		return fmt.Errorf("ping postgres: %w", err)
	}

	scheme := k8sruntime.NewScheme()
	utilruntime.Must(corev1.AddToScheme(scheme))
	k8sClient, err := client.New(ctrl.GetConfigOrDie(), client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("build k8s client: %w", err)
	}

	store := cpruntime.NewPostgresRunStore(db)
	if err := store.EnsureSchema(ctx); err != nil {
		return err
	}
	aimxsSKUFeatures, err := parseSKUFeaturesPolicy(cfg.AuthAIMXSSKUFeaturesJSON)
	if err != nil {
		return fmt.Errorf("parse AIMXS SKU feature policy: %w", err)
	}

	orchestrator := &cpruntime.Orchestrator{
		Namespace:           cfg.Namespace,
		Store:               store,
		ProviderRegistry:    cpruntime.NewProviderRegistry(k8sClient),
		ProfileMinPriority:  cfg.ProfileMinPriority,
		PolicyMinPriority:   cfg.PolicyMinPriority,
		EvidenceMinPriority: cfg.EvidenceMinPriority,
		RequirePolicyGrant:  cfg.AuthRequirePolicyGrant,
		AIMXSEntitlement: cpruntime.AIMXSEntitlementConfig{
			Enabled:               cfg.AuthRequireAIMXSEntitlement,
			ProviderNamePrefixes:  splitCommaList(cfg.AuthAIMXSProviderPrefixes),
			AllowedSKUs:           toLowerStringSet(splitCommaList(cfg.AuthAIMXSAllowedSKUs)),
			SKUFeatures:           aimxsSKUFeatures,
			RequiredFeatures:      toLowerStringSet(splitCommaList(cfg.AuthAIMXSRequiredFeatures)),
			RequireEntitlementKey: cfg.AuthAIMXSEntitlementTokenRequired,
		},
		RetentionDefaultClass: cfg.RetentionDefaultClass,
		PolicyLifecycle: cpruntime.PolicyLifecycleConfig{
			Enabled:          cfg.PolicyLifecycleEnabled,
			Mode:             cfg.PolicyLifecycleMode,
			AllowedPolicyIDs: toStringSet(splitCommaList(cfg.PolicyAllowedIDs)),
			MinVersion:       cfg.PolicyMinVersion,
			RolloutPercent:   cfg.PolicyRolloutPercent,
		},
	}
	orchestrator.RetentionClassTTLs, err = parseRetentionPolicy(cfg.RetentionPolicyJSON)
	if err != nil {
		return fmt.Errorf("parse retention policy: %w", err)
	}
	authEnforcer, err := cpruntime.NewAuthEnforcer(cpruntime.AuthConfig{
		Enabled:             cfg.AuthEnabled,
		Issuer:              cfg.AuthIssuer,
		Audience:            cfg.AuthAudience,
		JWKSURL:             cfg.AuthJWKSURL,
		HS256Secret:         cfg.AuthHS256Secret,
		JWKSCacheTTL:        cfg.AuthJWKSCacheTTL,
		RoleClaim:           cfg.AuthRoleClaim,
		ClientIDClaim:       cfg.AuthClientIDClaim,
		TenantClaim:         cfg.AuthTenantClaim,
		ProjectClaim:        cfg.AuthProjectClaim,
		CreateRoles:         splitCommaList(cfg.AuthCreateRoles),
		ReadRoles:           splitCommaList(cfg.AuthReadRoles),
		AllowedClientIDs:    splitCommaList(cfg.AuthAllowedClientIDs),
		RoleMappingsJSON:    cfg.AuthRoleMappingsJSON,
		PolicyMatrixJSON:    cfg.AuthPolicyMatrixJSON,
		RequirePolicyMatrix: cfg.AuthRequirePolicyMatrix,
	})
	if err != nil {
		return fmt.Errorf("configure runtime authn/authz: %w", err)
	}
	api := cpruntime.NewAPIServer(store, orchestrator, authEnforcer)

	log.Printf(
		"runtime orchestration service listening on %s namespace=%s authnEnabled=%t requirePolicyGrant=%t requireAIMXSEntitlement=%t policyLifecycleEnabled=%t policyLifecycleMode=%s",
		cfg.ListenAddr,
		cfg.Namespace,
		cfg.AuthEnabled,
		cfg.AuthRequirePolicyGrant,
		cfg.AuthRequireAIMXSEntitlement,
		cfg.PolicyLifecycleEnabled,
		cfg.PolicyLifecycleMode,
	)
	serverCtx := ctrl.SetupSignalHandler()
	err = cpruntime.StartHTTPServer(serverCtx, cpruntime.ServerConfig{ListenAddr: cfg.ListenAddr}, api.Routes())
	if err != nil && err != context.Canceled {
		return err
	}
	return nil
}

func postgresDSN(cfg Config) (string, error) {
	if dsn := stringsOrDefault(cfg.PostgresDSN, ""); dsn != "" {
		return dsn, nil
	}
	if cfg.PostgresUser == "" {
		return "", fmt.Errorf("postgres user is required (POSTGRES_USER or --postgres-user)")
	}
	if cfg.PostgresPassword == "" {
		return "", fmt.Errorf("postgres password is required (POSTGRES_PASSWORD or --postgres-password)")
	}
	if cfg.PostgresHost == "" || cfg.PostgresDB == "" {
		return "", fmt.Errorf("postgres host and db are required")
	}

	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(cfg.PostgresUser, cfg.PostgresPassword),
		Host:   fmt.Sprintf("%s:%d", cfg.PostgresHost, cfg.PostgresPort),
		Path:   cfg.PostgresDB,
	}
	q := u.Query()
	q.Set("sslmode", cfg.PostgresSSLMode)
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envIntOrDefault(key string, fallback int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	var out int
	if _, err := fmt.Sscanf(raw, "%d", &out); err != nil {
		return fallback
	}
	return out
}

func stringsOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func envBoolOrDefault(key string, fallback bool) bool {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return fallback
	}
	return parsed
}

func envDurationOrDefault(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return parsed
}

func splitCommaList(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if trimmed := strings.TrimSpace(p); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func toStringSet(values []string) map[string]struct{} {
	if len(values) == 0 {
		return nil
	}
	out := make(map[string]struct{}, len(values))
	for _, v := range values {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			out[trimmed] = struct{}{}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func toLowerStringSet(values []string) map[string]struct{} {
	if len(values) == 0 {
		return nil
	}
	out := make(map[string]struct{}, len(values))
	for _, v := range values {
		if trimmed := strings.ToLower(strings.TrimSpace(v)); trimmed != "" {
			out[trimmed] = struct{}{}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func parseSKUFeaturesPolicy(raw string) (map[string]map[string]struct{}, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	decoded := make(map[string][]string)
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, err
	}
	out := make(map[string]map[string]struct{}, len(decoded))
	for sku, features := range decoded {
		sku = strings.ToLower(strings.TrimSpace(sku))
		if sku == "" {
			continue
		}
		set := toLowerStringSet(features)
		if len(set) == 0 {
			continue
		}
		out[sku] = set
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func parseRetentionPolicy(raw string) (map[string]time.Duration, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	decoded := make(map[string]string)
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, err
	}
	out := make(map[string]time.Duration, len(decoded))
	for class, ttlRaw := range decoded {
		class = strings.TrimSpace(class)
		if class == "" {
			continue
		}
		ttlRaw = strings.TrimSpace(ttlRaw)
		if ttlRaw == "" {
			return nil, fmt.Errorf("retention policy class %q has empty duration", class)
		}
		ttl, err := time.ParseDuration(ttlRaw)
		if err != nil {
			return nil, fmt.Errorf("retention policy class %q: %w", class, err)
		}
		if ttl < 0 {
			return nil, fmt.Errorf("retention policy class %q has negative duration", class)
		}
		out[class] = ttl
	}
	return out, nil
}
