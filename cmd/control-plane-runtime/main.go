package main

import (
	"context"
	"database/sql"
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

	cpruntime "github.com/epydios/epydios-ai-control-plane/internal/runtime"
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

	AuthEnabled             bool
	AuthIssuer              string
	AuthAudience            string
	AuthJWKSURL             string
	AuthHS256Secret         string
	AuthJWKSCacheTTL        time.Duration
	AuthRoleClaim           string
	AuthClientIDClaim       string
	AuthTenantClaim         string
	AuthProjectClaim        string
	AuthCreateRoles         string
	AuthReadRoles           string
	AuthAllowedClientIDs    string
	AuthRoleMappingsJSON    string
	AuthPolicyMatrixJSON    string
	AuthRequirePolicyMatrix bool
	AuthRequirePolicyGrant  bool
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

		AuthEnabled:             envBoolOrDefault("AUTHN_ENABLED", false),
		AuthIssuer:              envOrDefault("AUTHN_ISSUER", ""),
		AuthAudience:            envOrDefault("AUTHN_AUDIENCE", ""),
		AuthJWKSURL:             envOrDefault("AUTHN_JWKS_URL", ""),
		AuthHS256Secret:         envOrDefault("AUTHN_HS256_SECRET", ""),
		AuthJWKSCacheTTL:        envDurationOrDefault("AUTHN_JWKS_CACHE_TTL", 5*time.Minute),
		AuthRoleClaim:           envOrDefault("AUTHN_ROLE_CLAIM", "roles"),
		AuthClientIDClaim:       envOrDefault("AUTHN_CLIENT_ID_CLAIM", "client_id"),
		AuthTenantClaim:         envOrDefault("AUTHN_TENANT_CLAIM", "tenant_id"),
		AuthProjectClaim:        envOrDefault("AUTHN_PROJECT_CLAIM", "project_id"),
		AuthCreateRoles:         envOrDefault("AUTHZ_CREATE_ROLES", "runtime.admin,runtime.run.create"),
		AuthReadRoles:           envOrDefault("AUTHZ_READ_ROLES", "runtime.admin,runtime.run.read"),
		AuthAllowedClientIDs:    envOrDefault("AUTHZ_ALLOWED_CLIENT_IDS", ""),
		AuthRoleMappingsJSON:    envOrDefault("AUTHZ_ROLE_PERMISSION_MAPPINGS_JSON", ""),
		AuthPolicyMatrixJSON:    envOrDefault("AUTHZ_POLICY_MATRIX_JSON", ""),
		AuthRequirePolicyMatrix: envBoolOrDefault("AUTHZ_POLICY_MATRIX_REQUIRED", false),
		AuthRequirePolicyGrant:  envBoolOrDefault("AUTHZ_REQUIRE_POLICY_GRANT", false),
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

	orchestrator := &cpruntime.Orchestrator{
		Namespace:           cfg.Namespace,
		Store:               store,
		ProviderRegistry:    cpruntime.NewProviderRegistry(k8sClient),
		ProfileMinPriority:  cfg.ProfileMinPriority,
		PolicyMinPriority:   cfg.PolicyMinPriority,
		EvidenceMinPriority: cfg.EvidenceMinPriority,
		RequirePolicyGrant:  cfg.AuthRequirePolicyGrant,
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

	log.Printf("runtime orchestration service listening on %s namespace=%s authnEnabled=%t requirePolicyGrant=%t", cfg.ListenAddr, cfg.Namespace, cfg.AuthEnabled, cfg.AuthRequirePolicyGrant)
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
