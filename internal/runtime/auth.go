package runtime

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	PermissionRunCreate = "runtime.run.create"
	PermissionRunRead   = "runtime.run.read"
)

var (
	ErrAuthRequired = errors.New("authorization bearer token is required")
	ErrInvalidToken = errors.New("invalid bearer token")
	ErrForbidden    = errors.New("forbidden")
)

type RuntimeIdentity struct {
	Subject    string
	ClientID   string
	Roles      []string
	TenantIDs  []string
	ProjectIDs []string
	Claims     map[string]interface{}
}

type AuthConfig struct {
	Enabled             bool
	Issuer              string
	Audience            string
	JWKSURL             string
	HS256Secret         string
	JWKSCacheTTL        time.Duration
	RoleClaim           string
	ClientIDClaim       string
	TenantClaim         string
	ProjectClaim        string
	CreateRoles         []string
	ReadRoles           []string
	AllowedClientIDs    []string
	RoleMappingsJSON    string
	PolicyMatrixJSON    string
	RequirePolicyMatrix bool
}

type AuthEnforcer struct {
	cfg                  AuthConfig
	parser               *jwt.Parser
	jwksCache            *jwksKeyCache
	rolePermissionMatrix map[string]map[string]struct{}
	policyRules          []AuthzPolicyRule
}

type AuthzRoleMapping struct {
	Role        string   `json:"role"`
	Permissions []string `json:"permissions"`
}

type AuthzRoleMappingDocument struct {
	Mappings []AuthzRoleMapping `json:"mappings"`
}

type AuthzPolicyRule struct {
	Name        string   `json:"name,omitempty"`
	Effect      string   `json:"effect"` // allow | deny
	Permissions []string `json:"permissions,omitempty"`
	Roles       []string `json:"roles,omitempty"`
	Subjects    []string `json:"subjects,omitempty"`
	ClientIDs   []string `json:"clientIds,omitempty"`
	Tenants     []string `json:"tenants,omitempty"`
	Projects    []string `json:"projects,omitempty"`
}

type authzPolicyMatrixDocument struct {
	Rules []AuthzPolicyRule `json:"rules"`
}

func NewAuthEnforcer(cfg AuthConfig) (*AuthEnforcer, error) {
	if !cfg.Enabled {
		return &AuthEnforcer{cfg: cfg}, nil
	}
	if strings.TrimSpace(cfg.JWKSURL) == "" && strings.TrimSpace(cfg.HS256Secret) == "" {
		return nil, fmt.Errorf("runtime auth enabled but neither JWKSURL nor HS256 secret is configured")
	}
	if strings.TrimSpace(cfg.RoleClaim) == "" {
		cfg.RoleClaim = "roles"
	}
	if strings.TrimSpace(cfg.ClientIDClaim) == "" {
		cfg.ClientIDClaim = "client_id"
	}
	if strings.TrimSpace(cfg.TenantClaim) == "" {
		cfg.TenantClaim = "tenant_id"
	}
	if strings.TrimSpace(cfg.ProjectClaim) == "" {
		cfg.ProjectClaim = "project_id"
	}
	if len(cfg.CreateRoles) == 0 {
		cfg.CreateRoles = []string{"runtime.admin", PermissionRunCreate}
	}
	if len(cfg.ReadRoles) == 0 {
		cfg.ReadRoles = []string{"runtime.admin", PermissionRunRead}
	}
	if cfg.JWKSCacheTTL <= 0 {
		cfg.JWKSCacheTTL = 5 * time.Minute
	}

	roleMatrix, err := compileRolePermissionMatrix(cfg)
	if err != nil {
		return nil, fmt.Errorf("compile role permission mappings: %w", err)
	}
	policyRules, err := compilePolicyMatrix(cfg.PolicyMatrixJSON)
	if err != nil {
		return nil, fmt.Errorf("compile policy matrix: %w", err)
	}
	if cfg.RequirePolicyMatrix && len(policyRules) == 0 {
		return nil, fmt.Errorf("runtime auth requires policy matrix but no policy rules are configured")
	}

	e := &AuthEnforcer{
		cfg:                  cfg,
		parser:               jwt.NewParser(jwt.WithValidMethods([]string{"RS256", "HS256"})),
		rolePermissionMatrix: roleMatrix,
		policyRules:          policyRules,
	}
	if strings.TrimSpace(cfg.JWKSURL) != "" {
		e.jwksCache = newJWKSKeyCache(cfg.JWKSURL, cfg.JWKSCacheTTL)
	}
	return e, nil
}

func (e *AuthEnforcer) Enabled() bool {
	return e != nil && e.cfg.Enabled
}

func (e *AuthEnforcer) AuthenticateRequest(r *http.Request) (*RuntimeIdentity, error) {
	if !e.Enabled() {
		return nil, nil
	}

	token, err := bearerToken(r.Header.Get("Authorization"))
	if err != nil {
		return nil, err
	}

	claims := jwt.MapClaims{}
	parsed, err := e.parser.ParseWithClaims(token, claims, e.keyFunc(r.Context()))
	if err != nil || parsed == nil || !parsed.Valid {
		if err == nil {
			err = errors.New("token parse failed")
		}
		return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	if err := e.validateRegisteredClaims(claims); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}

	roles := extractRolesFromClaims(claims, e.cfg.RoleClaim)
	clientID := extractClientID(claims, e.cfg.ClientIDClaim)
	tenantIDs := extractScopedValuesFromClaims(claims, e.cfg.TenantClaim, "tenant_id", "tenantId", "tenants")
	projectIDs := extractScopedValuesFromClaims(claims, e.cfg.ProjectClaim, "project_id", "projectId", "projects")
	subject := extractStringClaim(claims, "sub")
	if strings.TrimSpace(subject) == "" {
		return nil, fmt.Errorf("%w: subject claim is required", ErrInvalidToken)
	}

	return &RuntimeIdentity{
		Subject:    subject,
		ClientID:   clientID,
		Roles:      sortedUnique(roles),
		TenantIDs:  tenantIDs,
		ProjectIDs: projectIDs,
		Claims:     cloneMapClaims(claims),
	}, nil
}

func (i *RuntimeIdentity) AllowsTenant(tenantID string) bool {
	if i == nil || len(i.TenantIDs) == 0 {
		return true
	}
	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return false
	}
	return containsExactString(i.TenantIDs, tenantID)
}

func (i *RuntimeIdentity) AllowsProject(projectID string) bool {
	if i == nil || len(i.ProjectIDs) == 0 {
		return true
	}
	projectID = strings.TrimSpace(projectID)
	if projectID == "" {
		return false
	}
	return containsExactString(i.ProjectIDs, projectID)
}

func (e *AuthEnforcer) Authorize(identity *RuntimeIdentity, permission string) error {
	if !e.Enabled() {
		return nil
	}
	if identity == nil {
		return ErrForbidden
	}

	if len(e.cfg.AllowedClientIDs) > 0 {
		allowed := make(map[string]struct{}, len(e.cfg.AllowedClientIDs))
		for _, cid := range e.cfg.AllowedClientIDs {
			if trimmed := strings.TrimSpace(cid); trimmed != "" {
				allowed[trimmed] = struct{}{}
			}
		}
		if len(allowed) > 0 {
			if _, ok := allowed[identity.ClientID]; !ok {
				return fmt.Errorf("%w: client_id not allowed", ErrForbidden)
			}
		}
	}

	if !e.identityHasPermission(identity, permission) {
		return fmt.Errorf("%w: role mapping denied for permission=%s", ErrForbidden, permission)
	}
	return nil
}

func (e *AuthEnforcer) AuthorizeScoped(identity *RuntimeIdentity, permission, tenantID, projectID string) error {
	if !e.Enabled() {
		return nil
	}
	if identity == nil {
		return ErrForbidden
	}
	tenantID = strings.TrimSpace(tenantID)
	projectID = strings.TrimSpace(projectID)

	if len(e.policyRules) == 0 {
		return nil
	}

	allowMatched := false
	for _, rule := range e.policyRules {
		if !ruleMatchesIdentity(rule, identity) {
			continue
		}
		if !selectorMatches(rule.Permissions, permission) {
			continue
		}
		if !selectorMatches(rule.Tenants, tenantID) {
			continue
		}
		if !selectorMatches(rule.Projects, projectID) {
			continue
		}

		switch strings.ToLower(strings.TrimSpace(rule.Effect)) {
		case "deny":
			return fmt.Errorf("%w: denied by policy rule %q", ErrForbidden, rule.Name)
		case "allow":
			allowMatched = true
		}
	}
	if !allowMatched {
		return fmt.Errorf("%w: no matching allow policy rule for permission=%s tenant=%q project=%q", ErrForbidden, permission, tenantID, projectID)
	}
	return nil
}

func (e *AuthEnforcer) validateRegisteredClaims(claims jwt.MapClaims) error {
	if strings.TrimSpace(e.cfg.Issuer) != "" {
		iss := extractStringClaim(claims, "iss")
		if iss != e.cfg.Issuer {
			return fmt.Errorf("issuer mismatch: got=%q want=%q", iss, e.cfg.Issuer)
		}
	}
	if strings.TrimSpace(e.cfg.Audience) != "" {
		if !audienceContains(claims["aud"], e.cfg.Audience) {
			return fmt.Errorf("audience mismatch: required=%q", e.cfg.Audience)
		}
	}
	validator := jwt.NewValidator()
	if err := validator.Validate(claims); err != nil {
		return err
	}
	return nil
}

func (e *AuthEnforcer) keyFunc(ctx context.Context) jwt.Keyfunc {
	return func(token *jwt.Token) (interface{}, error) {
		switch token.Method.Alg() {
		case jwt.SigningMethodHS256.Alg():
			if strings.TrimSpace(e.cfg.HS256Secret) == "" {
				return nil, fmt.Errorf("HS256 token received but HS256 secret is not configured")
			}
			return []byte(e.cfg.HS256Secret), nil
		case jwt.SigningMethodRS256.Alg():
			if e.jwksCache == nil {
				return nil, fmt.Errorf("RS256 token received but JWKS cache is not configured")
			}
			kid, _ := token.Header["kid"].(string)
			return e.jwksCache.PublicKey(ctx, kid)
		default:
			return nil, fmt.Errorf("unsupported JWT alg=%q", token.Method.Alg())
		}
	}
}

func bearerToken(header string) (string, error) {
	header = strings.TrimSpace(header)
	if header == "" {
		return "", ErrAuthRequired
	}
	parts := strings.SplitN(header, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || strings.TrimSpace(parts[1]) == "" {
		return "", fmt.Errorf("%w: expected Authorization: Bearer <token>", ErrAuthRequired)
	}
	return strings.TrimSpace(parts[1]), nil
}

func extractRolesFromClaims(claims map[string]interface{}, roleClaim string) []string {
	var roles []string
	roles = append(roles, claimStrings(claims[roleClaim])...)
	roles = append(roles, claimStrings(claims["groups"])...)

	// Permit scope-based role grants for service-to-service clients.
	scopeRaw, _ := claims["scope"].(string)
	if scopeRaw != "" {
		roles = append(roles, splitList(scopeRaw, " ")...)
	}
	return roles
}

func extractClientID(claims map[string]interface{}, claimName string) string {
	out := extractStringClaim(claims, claimName)
	if out != "" {
		return out
	}
	out = extractStringClaim(claims, "client_id")
	if out != "" {
		return out
	}
	return extractStringClaim(claims, "azp")
}

func extractScopedValuesFromClaims(claims map[string]interface{}, primaryClaim string, fallbackClaims ...string) []string {
	out := make([]string, 0, 4)
	seen := make(map[string]struct{}, 4)

	addClaimValues := func(claimName string) {
		claimName = strings.TrimSpace(claimName)
		if claimName == "" {
			return
		}
		for _, value := range claimStrings(claims[claimName]) {
			trimmed := strings.TrimSpace(value)
			if trimmed == "" {
				continue
			}
			if _, ok := seen[trimmed]; ok {
				continue
			}
			seen[trimmed] = struct{}{}
			out = append(out, trimmed)
		}
	}

	addClaimValues(primaryClaim)
	for _, claimName := range fallbackClaims {
		if strings.EqualFold(strings.TrimSpace(claimName), strings.TrimSpace(primaryClaim)) {
			continue
		}
		addClaimValues(claimName)
	}
	return sortedUnique(out)
}

func extractStringClaim(claims map[string]interface{}, name string) string {
	v, _ := claims[name]
	switch x := v.(type) {
	case string:
		return strings.TrimSpace(x)
	default:
		return ""
	}
}

func claimStrings(v interface{}) []string {
	switch x := v.(type) {
	case []string:
		return x
	case []interface{}:
		out := make([]string, 0, len(x))
		for _, item := range x {
			if s, ok := item.(string); ok {
				out = append(out, s)
			}
		}
		return out
	case string:
		return splitList(x, ",")
	default:
		return nil
	}
}

func splitList(raw, sep string) []string {
	items := strings.Split(raw, sep)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func compileRolePermissionMatrix(cfg AuthConfig) (map[string]map[string]struct{}, error) {
	matrix := make(map[string]map[string]struct{})

	add := func(role, permission string) {
		role = strings.TrimSpace(role)
		permission = strings.TrimSpace(permission)
		if role == "" || permission == "" {
			return
		}
		perms, ok := matrix[role]
		if !ok {
			perms = make(map[string]struct{})
			matrix[role] = perms
		}
		perms[permission] = struct{}{}
	}

	for _, role := range cfg.CreateRoles {
		add(role, PermissionRunCreate)
	}
	for _, role := range cfg.ReadRoles {
		add(role, PermissionRunRead)
	}

	raw := strings.TrimSpace(cfg.RoleMappingsJSON)
	if raw == "" {
		return matrix, nil
	}

	var doc AuthzRoleMappingDocument
	parsedDoc := false
	if err := json.Unmarshal([]byte(raw), &doc); err == nil && len(doc.Mappings) > 0 {
		parsedDoc = true
	} else if err == nil && len(doc.Mappings) == 0 {
		parsedDoc = true
	}

	if !parsedDoc {
		var mappings []AuthzRoleMapping
		if err := json.Unmarshal([]byte(raw), &mappings); err == nil {
			doc.Mappings = mappings
			parsedDoc = true
		}
	}

	if !parsedDoc {
		var byRole map[string][]string
		if err := json.Unmarshal([]byte(raw), &byRole); err == nil {
			for role, permissions := range byRole {
				for _, permission := range permissions {
					add(role, permission)
				}
			}
			return matrix, nil
		}
	}

	if !parsedDoc {
		return nil, fmt.Errorf("invalid role mapping JSON")
	}
	for _, mapping := range doc.Mappings {
		for _, permission := range mapping.Permissions {
			add(mapping.Role, permission)
		}
	}
	return matrix, nil
}

func compilePolicyMatrix(raw string) ([]AuthzPolicyRule, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	var rules []AuthzPolicyRule
	var doc authzPolicyMatrixDocument
	if err := json.Unmarshal([]byte(raw), &doc); err == nil && len(doc.Rules) > 0 {
		rules = doc.Rules
	} else if err == nil && len(doc.Rules) == 0 {
		return nil, nil
	} else {
		if err := json.Unmarshal([]byte(raw), &rules); err != nil {
			return nil, fmt.Errorf("invalid policy matrix JSON: %w", err)
		}
	}

	normalized := make([]AuthzPolicyRule, 0, len(rules))
	for idx, rule := range rules {
		effect := strings.ToLower(strings.TrimSpace(rule.Effect))
		if effect == "" {
			effect = "allow"
		}
		if effect != "allow" && effect != "deny" {
			return nil, fmt.Errorf("policy rule[%d] has invalid effect %q", idx, rule.Effect)
		}
		name := strings.TrimSpace(rule.Name)
		if name == "" {
			name = fmt.Sprintf("policy-rule-%d", idx+1)
		}

		rule.Name = name
		rule.Effect = effect
		rule.Permissions = sortedUnique(rule.Permissions)
		rule.Roles = sortedUnique(rule.Roles)
		rule.Subjects = sortedUnique(rule.Subjects)
		rule.ClientIDs = sortedUnique(rule.ClientIDs)
		rule.Tenants = sortedUnique(rule.Tenants)
		rule.Projects = sortedUnique(rule.Projects)
		normalized = append(normalized, rule)
	}
	return normalized, nil
}

func (e *AuthEnforcer) identityHasPermission(identity *RuntimeIdentity, permission string) bool {
	if identity == nil {
		return false
	}
	permission = strings.TrimSpace(permission)
	if permission == "" {
		return false
	}
	for _, role := range identity.Roles {
		role = strings.TrimSpace(role)
		if role == "" {
			continue
		}
		perms, ok := e.rolePermissionMatrix[role]
		if !ok {
			continue
		}
		if _, ok := perms["*"]; ok {
			return true
		}
		if _, ok := perms[permission]; ok {
			return true
		}
	}
	return false
}

func ruleMatchesIdentity(rule AuthzPolicyRule, identity *RuntimeIdentity) bool {
	if identity == nil {
		return false
	}
	if len(rule.Subjects) > 0 && !selectorMatches(rule.Subjects, identity.Subject) {
		return false
	}
	if len(rule.ClientIDs) > 0 && !selectorMatches(rule.ClientIDs, identity.ClientID) {
		return false
	}
	if len(rule.Roles) > 0 {
		roleMatched := false
		for _, role := range identity.Roles {
			if selectorMatches(rule.Roles, role) {
				roleMatched = true
				break
			}
		}
		if !roleMatched {
			return false
		}
	}
	return true
}

func selectorMatches(selectors []string, value string) bool {
	if len(selectors) == 0 {
		return true
	}
	value = strings.TrimSpace(value)
	for _, selector := range selectors {
		selector = strings.TrimSpace(selector)
		if selector == "" {
			continue
		}
		if selector == "*" {
			return true
		}
		if strings.HasSuffix(selector, "*") {
			prefix := strings.TrimSuffix(selector, "*")
			if strings.HasPrefix(value, prefix) {
				return true
			}
			continue
		}
		if selector == value {
			return true
		}
	}
	return false
}

func sortedUnique(items []string) []string {
	set := make(map[string]struct{}, len(items))
	out := make([]string, 0, len(items))
	for _, item := range items {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		if _, exists := set[trimmed]; exists {
			continue
		}
		set[trimmed] = struct{}{}
		out = append(out, trimmed)
	}
	// Stable deterministic ordering for logs/debugging.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func containsExactString(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}

func audienceContains(claim interface{}, target string) bool {
	target = strings.TrimSpace(target)
	if target == "" {
		return true
	}
	switch x := claim.(type) {
	case string:
		return strings.TrimSpace(x) == target
	case []interface{}:
		for _, item := range x {
			if s, ok := item.(string); ok && strings.TrimSpace(s) == target {
				return true
			}
		}
		return false
	case []string:
		for _, item := range x {
			if strings.TrimSpace(item) == target {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func cloneMapClaims(in map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

type runtimeIdentityKey struct{}

func withRuntimeIdentity(ctx context.Context, identity *RuntimeIdentity) context.Context {
	if identity == nil {
		return ctx
	}
	return context.WithValue(ctx, runtimeIdentityKey{}, identity)
}

func RuntimeIdentityFromContext(ctx context.Context) (*RuntimeIdentity, bool) {
	if ctx == nil {
		return nil, false
	}
	identity, ok := ctx.Value(runtimeIdentityKey{}).(*RuntimeIdentity)
	return identity, ok && identity != nil
}

type jwksKeyCache struct {
	url       string
	ttl       time.Duration
	http      *http.Client
	mu        sync.RWMutex
	keys      map[string]*rsa.PublicKey
	expiresAt time.Time
}

type jwksDocument struct {
	Keys []jwkKey `json:"keys"`
}

type jwkKey struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func newJWKSKeyCache(url string, ttl time.Duration) *jwksKeyCache {
	return &jwksKeyCache{
		url:  strings.TrimSpace(url),
		ttl:  ttl,
		http: &http.Client{Timeout: 5 * time.Second},
		keys: make(map[string]*rsa.PublicKey),
	}
}

func (c *jwksKeyCache) PublicKey(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	kid = strings.TrimSpace(kid)

	if key := c.currentKey(kid); key != nil {
		return key, nil
	}
	if err := c.refresh(ctx); err != nil {
		return nil, err
	}
	if key := c.currentKey(kid); key != nil {
		return key, nil
	}
	if kid == "" && len(c.keys) == 1 {
		for _, key := range c.keys {
			return key, nil
		}
	}
	return nil, fmt.Errorf("jwks key not found for kid=%q", kid)
}

func (c *jwksKeyCache) currentKey(kid string) *rsa.PublicKey {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if time.Now().Before(c.expiresAt) {
		if kid == "" && len(c.keys) == 1 {
			for _, key := range c.keys {
				return key
			}
		}
		return c.keys[kid]
	}
	return nil
}

func (c *jwksKeyCache) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return fmt.Errorf("build jwks request: %w", err)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("fetch jwks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("fetch jwks status=%d", resp.StatusCode)
	}

	var doc jwksDocument
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("decode jwks: %w", err)
	}

	parsed := make(map[string]*rsa.PublicKey)
	for _, item := range doc.Keys {
		if strings.ToUpper(strings.TrimSpace(item.Kty)) != "RSA" {
			continue
		}
		key, err := parseRSAPublicKey(item.N, item.E)
		if err != nil {
			continue
		}
		if strings.TrimSpace(item.Kid) != "" {
			parsed[item.Kid] = key
		}
	}
	if len(parsed) == 0 {
		return fmt.Errorf("jwks contains no usable RSA keys")
	}

	c.mu.Lock()
	c.keys = parsed
	c.expiresAt = time.Now().Add(c.ttl)
	c.mu.Unlock()
	return nil
}

func parseRSAPublicKey(nB64URL, eB64URL string) (*rsa.PublicKey, error) {
	nb, err := base64.RawURLEncoding.DecodeString(nB64URL)
	if err != nil {
		return nil, err
	}
	eb, err := base64.RawURLEncoding.DecodeString(eB64URL)
	if err != nil {
		return nil, err
	}
	n := new(big.Int).SetBytes(nb)
	eBig := new(big.Int).SetBytes(eb)
	if n.Sign() <= 0 || eBig.Sign() <= 0 {
		return nil, fmt.Errorf("invalid RSA jwk modulus/exponent")
	}
	e := int(eBig.Int64())
	if e <= 0 {
		return nil, fmt.Errorf("invalid RSA exponent")
	}
	return &rsa.PublicKey{N: n, E: e}, nil
}
