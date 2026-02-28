package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type config struct {
	ListenAddr      string
	ProviderType    string
	ProviderID      string
	ProviderVersion string
	ContractVersion string
	CapabilitiesRaw string
	TLSCertFile     string
	TLSKeyFile      string
	ClientCAFile    string
	RequireBearer   bool
	BearerTokenFile string
}

type server struct {
	cfg          config
	capabilities []string
	bearerToken  string

	mu       sync.RWMutex
	evidence map[string]storedEvidence
}

type storedEvidence struct {
	RunID string
}

type providerCapabilitiesResponse struct {
	ProviderType    string   `json:"providerType"`
	ProviderID      string   `json:"providerId"`
	ContractVersion string   `json:"contractVersion"`
	ProviderVersion string   `json:"providerVersion"`
	Capabilities    []string `json:"capabilities"`
}

type providerError struct {
	ErrorCode string                 `json:"errorCode"`
	Message   string                 `json:"message"`
	Retryable bool                   `json:"retryable"`
	Details   map[string]interface{} `json:"details,omitempty"`
}

type objectMeta struct {
	RequestID string `json:"requestId"`
	Timestamp string `json:"timestamp"`
	TenantID  string `json:"tenantId,omitempty"`
	ProjectID string `json:"projectId,omitempty"`
	Env       string `json:"environment,omitempty"`
}

type subjectRef struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type actionRef struct {
	Verb string `json:"verb"`
}

type taskRef struct {
	Kind         string `json:"kind,omitempty"`
	Sensitivity  string `json:"sensitivity,omitempty"`
	LatencyClass string `json:"latencyClass,omitempty"`
}

type profileDefaults struct {
	ProfileID string `json:"profileId,omitempty"`
}

type profileResolveRequest struct {
	Meta     objectMeta             `json:"meta"`
	Task     taskRef                `json:"task,omitempty"`
	Defaults profileDefaults        `json:"defaults,omitempty"`
	Context  map[string]interface{} `json:"context,omitempty"`
}

type profileResolveResponse struct {
	ProfileID            string                 `json:"profileId"`
	ProfileVersion       string                 `json:"profileVersion,omitempty"`
	Source               string                 `json:"source,omitempty"`
	TTLSeconds           int                    `json:"ttlSeconds,omitempty"`
	Attributes           map[string]interface{} `json:"attributes,omitempty"`
	RequiredCapabilities []string               `json:"requiredCapabilities,omitempty"`
}

type policyEvaluateRequest struct {
	Meta    objectMeta `json:"meta"`
	Subject subjectRef `json:"subject"`
	Action  actionRef  `json:"action"`
	Mode    string     `json:"mode,omitempty"`
}

type decisionReason struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type policyBundleRef struct {
	PolicyID      string `json:"policyId"`
	PolicyVersion string `json:"policyVersion"`
	Checksum      string `json:"checksum"`
}

type policyEvaluateResponse struct {
	Decision     string                 `json:"decision"`
	Reasons      []decisionReason       `json:"reasons,omitempty"`
	PolicyBundle policyBundleRef        `json:"policyBundle"`
	EvidenceRefs []string               `json:"evidenceRefs,omitempty"`
	Output       map[string]interface{} `json:"output,omitempty"`
}

type policyBundleValidationRequest struct {
	Meta                 objectMeta             `json:"meta"`
	Bundle               map[string]interface{} `json:"bundle"`
	ExpectedCapabilities []string               `json:"expectedCapabilities,omitempty"`
}

type policyBundleValidationResponse struct {
	Valid                  bool             `json:"valid"`
	Errors                 []decisionReason `json:"errors,omitempty"`
	DiscoveredCapabilities []string         `json:"discoveredCapabilities,omitempty"`
}

type evidenceRecordRequest struct {
	Meta           objectMeta             `json:"meta"`
	EventType      string                 `json:"eventType"`
	EventID        string                 `json:"eventId,omitempty"`
	RunID          string                 `json:"runId,omitempty"`
	Stage          string                 `json:"stage,omitempty"`
	Payload        map[string]interface{} `json:"payload,omitempty"`
	RetentionClass string                 `json:"retentionClass,omitempty"`
}

type evidenceRecordResponse struct {
	Accepted   bool   `json:"accepted"`
	EvidenceID string `json:"evidenceId"`
	Checksum   string `json:"checksum"`
	StorageURI string `json:"storageUri"`
	BundleHint string `json:"bundleHint,omitempty"`
}

type evidenceFinalizeBundleRequest struct {
	Meta           objectMeta        `json:"meta"`
	BundleID       string            `json:"bundleId"`
	RunID          string            `json:"runId,omitempty"`
	EvidenceIDs    []string          `json:"evidenceIds,omitempty"`
	RetentionClass string            `json:"retentionClass,omitempty"`
	Annotations    map[string]string `json:"annotations,omitempty"`
}

type evidenceFinalizeBundleResponse struct {
	BundleID         string `json:"bundleId"`
	ManifestURI      string `json:"manifestUri"`
	ManifestChecksum string `json:"manifestChecksum"`
	ItemCount        int    `json:"itemCount"`
}

func main() {
	cfg := parseFlags()
	if err := validateConfig(cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}

	capabilities := resolveCapabilities(cfg.ProviderType, cfg.CapabilitiesRaw)
	bearerToken, err := loadBearerToken(cfg.RequireBearer, cfg.BearerTokenFile)
	if err != nil {
		log.Fatalf("load bearer token: %v", err)
	}

	tlsCfg, err := buildTLSConfig(cfg)
	if err != nil {
		log.Fatalf("build TLS config: %v", err)
	}

	s := &server{
		cfg:          cfg,
		capabilities: capabilities,
		bearerToken:  bearerToken,
		evidence:     make(map[string]storedEvidence),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1alpha1/capabilities", s.handleCapabilities)
	mux.HandleFunc("/v1alpha1/profile-resolver/resolve", s.handleProfileResolve)
	mux.HandleFunc("/v1alpha1/policy-provider/evaluate", s.handlePolicyEvaluate)
	mux.HandleFunc("/v1alpha1/policy-provider/validate-bundle", s.handlePolicyValidateBundle)
	mux.HandleFunc("/v1alpha1/evidence-provider/record", s.handleEvidenceRecord)
	mux.HandleFunc("/v1alpha1/evidence-provider/finalize-bundle", s.handleEvidenceFinalizeBundle)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           s.loggingMiddleware(mux),
		TLSConfig:         tlsCfg,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf(
			"mTLS capabilities provider listening on %s (providerType=%s, providerId=%s, requireBearer=%t)",
			cfg.ListenAddr,
			cfg.ProviderType,
			cfg.ProviderID,
			cfg.RequireBearer,
		)
		if serveErr := httpServer.ListenAndServeTLS("", ""); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			log.Fatalf("listen and serve: %v", serveErr)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
}

func parseFlags() config {
	var cfg config
	flag.StringVar(&cfg.ListenAddr, "listen", ":8443", "listen address")
	flag.StringVar(&cfg.ProviderType, "provider-type", "ProfileResolver", "provider type to advertise")
	flag.StringVar(&cfg.ProviderID, "provider-id", "mtls-provider", "provider id to advertise")
	flag.StringVar(&cfg.ProviderVersion, "provider-version", "0.1.0", "provider version to advertise")
	flag.StringVar(&cfg.ContractVersion, "contract-version", "v1alpha1", "contract version to advertise")
	flag.StringVar(&cfg.CapabilitiesRaw, "capabilities", "", "comma-separated capabilities override")
	flag.StringVar(&cfg.TLSCertFile, "tls-cert-file", "/tls/tls.crt", "server TLS certificate file")
	flag.StringVar(&cfg.TLSKeyFile, "tls-key-file", "/tls/tls.key", "server TLS private key file")
	flag.StringVar(&cfg.ClientCAFile, "client-ca-file", "/tls/ca.crt", "client CA certificate file")
	flag.BoolVar(&cfg.RequireBearer, "require-bearer", false, "require Authorization: Bearer token")
	flag.StringVar(&cfg.BearerTokenFile, "bearer-token-file", "", "bearer token file (required when require-bearer=true)")
	flag.Parse()
	return cfg
}

func validateConfig(cfg config) error {
	if strings.TrimSpace(cfg.ProviderType) == "" {
		return fmt.Errorf("provider-type is required")
	}
	if strings.TrimSpace(cfg.ProviderID) == "" {
		return fmt.Errorf("provider-id is required")
	}
	if strings.TrimSpace(cfg.ContractVersion) == "" {
		return fmt.Errorf("contract-version is required")
	}
	if strings.TrimSpace(cfg.TLSCertFile) == "" || strings.TrimSpace(cfg.TLSKeyFile) == "" {
		return fmt.Errorf("tls-cert-file and tls-key-file are required")
	}
	if strings.TrimSpace(cfg.ClientCAFile) == "" {
		return fmt.Errorf("client-ca-file is required")
	}
	if cfg.RequireBearer && strings.TrimSpace(cfg.BearerTokenFile) == "" {
		return fmt.Errorf("bearer-token-file is required when require-bearer=true")
	}
	return nil
}

func loadBearerToken(required bool, path string) (string, error) {
	if !required {
		return "", nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("bearer token file %q is empty", path)
	}
	return token, nil
}

func buildTLSConfig(cfg config) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
	if err != nil {
		return nil, err
	}

	caPEM, err := os.ReadFile(cfg.ClientCAFile)
	if err != nil {
		return nil, err
	}
	caPool := x509.NewCertPool()
	if ok := caPool.AppendCertsFromPEM(caPEM); !ok {
		return nil, fmt.Errorf("failed to parse client CA PEM from %q", cfg.ClientCAFile)
	}

	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
		ClientCAs:    caPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
	}, nil
}

func resolveCapabilities(providerType, override string) []string {
	if strings.TrimSpace(override) != "" {
		parts := strings.Split(override, ",")
		out := make([]string, 0, len(parts))
		for _, part := range parts {
			value := strings.TrimSpace(part)
			if value != "" {
				out = append(out, value)
			}
		}
		if len(out) > 0 {
			return out
		}
	}

	switch providerType {
	case "ProfileResolver":
		return []string{"profile.resolve"}
	case "PolicyProvider":
		return []string{"policy.evaluate", "policy.validate_bundle"}
	case "EvidenceProvider":
		return []string{"evidence.record", "evidence.finalize_bundle"}
	default:
		return []string{"capability.unknown"}
	}
}

func (s *server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	resp := providerCapabilitiesResponse{
		ProviderType:    s.cfg.ProviderType,
		ProviderID:      s.cfg.ProviderID,
		ContractVersion: s.cfg.ContractVersion,
		ProviderVersion: s.cfg.ProviderVersion,
		Capabilities:    s.capabilities,
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handleProfileResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	if s.cfg.ProviderType != "ProfileResolver" {
		writeProviderError(w, http.StatusNotFound, "UNSUPPORTED_ENDPOINT", "profile endpoint is not supported by this provider type", false, nil)
		return
	}

	defer r.Body.Close()
	var req profileResolveRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateMeta(req.Meta); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	profileID := strings.TrimSpace(req.Defaults.ProfileID)
	if profileID == "" {
		profileID = "EPYDIOS_MTLS_PROFILE_BASELINE"
	}

	resp := profileResolveResponse{
		ProfileID:      profileID,
		ProfileVersion: "v1",
		Source:         "mtls-fixture",
		TTLSeconds:     300,
		Attributes: map[string]interface{}{
			"providerId":      s.cfg.ProviderID,
			"requestId":       strings.TrimSpace(req.Meta.RequestID),
			"taskKind":        strings.TrimSpace(req.Task.Kind),
			"taskSensitivity": strings.TrimSpace(req.Task.Sensitivity),
		},
		RequiredCapabilities: []string{"profile.resolve"},
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handlePolicyEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	if s.cfg.ProviderType != "PolicyProvider" {
		writeProviderError(w, http.StatusNotFound, "UNSUPPORTED_ENDPOINT", "policy endpoint is not supported by this provider type", false, nil)
		return
	}

	defer r.Body.Close()
	var req policyEvaluateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validatePolicyEvaluateRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode == "" {
		mode = "enforce"
	}

	decision := "ALLOW"
	reasons := []decisionReason{{Code: "ALLOW_DEFAULT", Message: "Allowed by mTLS fixture policy provider."}}
	if strings.EqualFold(strings.TrimSpace(req.Action.Verb), "delete") && mode != "audit" {
		decision = "DENY"
		reasons = []decisionReason{{Code: "DELETE_DENIED", Message: "delete verb is denied by mTLS fixture policy provider."}}
	}

	policyChecksum := sha256JSON(map[string]string{
		"providerId": s.cfg.ProviderID,
		"policyId":   "EPYDIOS_MTLS_FIXTURE_POLICY",
		"version":    "v1",
	})

	resp := policyEvaluateResponse{
		Decision: decision,
		Reasons:  reasons,
		PolicyBundle: policyBundleRef{
			PolicyID:      "EPYDIOS_MTLS_FIXTURE_POLICY",
			PolicyVersion: "v1",
			Checksum:      policyChecksum,
		},
		EvidenceRefs: []string{"policy:" + strings.TrimSpace(req.Meta.RequestID)},
		Output: map[string]interface{}{
			"engine":     "mtls-fixture",
			"providerId": s.cfg.ProviderID,
			"mode":       mode,
		},
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handlePolicyValidateBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	if s.cfg.ProviderType != "PolicyProvider" {
		writeProviderError(w, http.StatusNotFound, "UNSUPPORTED_ENDPOINT", "policy endpoint is not supported by this provider type", false, nil)
		return
	}

	defer r.Body.Close()
	var req policyBundleValidationRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateMeta(req.Meta); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}
	if req.Bundle == nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", "bundle is required", false, nil)
		return
	}

	resp := policyBundleValidationResponse{
		Valid:                  true,
		DiscoveredCapabilities: append([]string(nil), s.capabilities...),
	}

	var errs []decisionReason
	if strings.TrimSpace(asString(req.Bundle["policyId"])) == "" {
		errs = append(errs, decisionReason{Code: "POLICY_ID_REQUIRED", Message: "bundle.policyId is required"})
	}
	if strings.TrimSpace(asString(req.Bundle["policyVersion"])) == "" {
		errs = append(errs, decisionReason{Code: "POLICY_VERSION_REQUIRED", Message: "bundle.policyVersion is required"})
	}
	for _, cap := range req.ExpectedCapabilities {
		if !containsString(s.capabilities, cap) {
			errs = append(errs, decisionReason{Code: "UNSUPPORTED_CAPABILITY", Message: fmt.Sprintf("expected capability %q is not supported", cap)})
		}
	}
	if len(errs) > 0 {
		resp.Valid = false
		resp.Errors = errs
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handleEvidenceRecord(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	if s.cfg.ProviderType != "EvidenceProvider" {
		writeProviderError(w, http.StatusNotFound, "UNSUPPORTED_ENDPOINT", "evidence endpoint is not supported by this provider type", false, nil)
		return
	}

	defer r.Body.Close()
	var req evidenceRecordRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateEvidenceRecordRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	checksum, evidenceID := deriveEvidenceID(req)
	retention := strings.TrimSpace(req.RetentionClass)
	if retention == "" {
		retention = "standard"
	}

	s.mu.Lock()
	s.evidence[evidenceID] = storedEvidence{RunID: strings.TrimSpace(req.RunID)}
	s.mu.Unlock()

	storageURI := joinURIPath("memory://"+s.cfg.ProviderID, "evidence", evidenceID+".json")
	resp := evidenceRecordResponse{
		Accepted:   true,
		EvidenceID: evidenceID,
		Checksum:   checksum,
		StorageURI: storageURI,
		BundleHint: buildBundleHint(req),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handleEvidenceFinalizeBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorize(w, r) {
		return
	}
	if s.cfg.ProviderType != "EvidenceProvider" {
		writeProviderError(w, http.StatusNotFound, "UNSUPPORTED_ENDPOINT", "evidence endpoint is not supported by this provider type", false, nil)
		return
	}

	defer r.Body.Close()
	var req evidenceFinalizeBundleRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateEvidenceFinalizeRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	itemCount, ids := s.resolveFinalizeItems(req)
	manifestPayload := map[string]interface{}{
		"providerId":     s.cfg.ProviderID,
		"bundleId":       strings.TrimSpace(req.BundleID),
		"runId":          strings.TrimSpace(req.RunID),
		"retentionClass": strings.TrimSpace(req.RetentionClass),
		"evidenceIds":    ids,
		"annotations":    req.Annotations,
		"itemCount":      itemCount,
		"finalizedAt":    time.Now().UTC().Format(time.RFC3339),
	}
	manifestChecksum := sha256JSON(manifestPayload)
	manifestURI := joinURIPath("memory://"+s.cfg.ProviderID+"/bundles", strings.TrimSpace(req.BundleID)+".json")

	resp := evidenceFinalizeBundleResponse{
		BundleID:         strings.TrimSpace(req.BundleID),
		ManifestURI:      manifestURI,
		ManifestChecksum: manifestChecksum,
		ItemCount:        itemCount,
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) resolveFinalizeItems(req evidenceFinalizeBundleRequest) (int, []string) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(req.EvidenceIDs) > 0 {
		ids := normalizeIDs(req.EvidenceIDs)
		return len(ids), ids
	}
	if strings.TrimSpace(req.RunID) == "" {
		return 0, nil
	}

	var ids []string
	for evidenceID, rec := range s.evidence {
		if rec.RunID == strings.TrimSpace(req.RunID) {
			ids = append(ids, evidenceID)
		}
	}
	sort.Strings(ids)
	return len(ids), ids
}

func validateMeta(meta objectMeta) error {
	if strings.TrimSpace(meta.RequestID) == "" {
		return fmt.Errorf("meta.requestId is required")
	}
	if strings.TrimSpace(meta.Timestamp) == "" {
		return fmt.Errorf("meta.timestamp is required")
	}
	return nil
}

func validatePolicyEvaluateRequest(req policyEvaluateRequest) error {
	if err := validateMeta(req.Meta); err != nil {
		return err
	}
	if strings.TrimSpace(req.Subject.Type) == "" {
		return fmt.Errorf("subject.type is required")
	}
	if strings.TrimSpace(req.Subject.ID) == "" {
		return fmt.Errorf("subject.id is required")
	}
	if strings.TrimSpace(req.Action.Verb) == "" {
		return fmt.Errorf("action.verb is required")
	}
	return nil
}

func validateEvidenceRecordRequest(req evidenceRecordRequest) error {
	if err := validateMeta(req.Meta); err != nil {
		return err
	}
	if strings.TrimSpace(req.EventType) == "" {
		return fmt.Errorf("eventType is required")
	}
	return nil
}

func validateEvidenceFinalizeRequest(req evidenceFinalizeBundleRequest) error {
	if err := validateMeta(req.Meta); err != nil {
		return err
	}
	if strings.TrimSpace(req.BundleID) == "" {
		return fmt.Errorf("bundleId is required")
	}
	return nil
}

func deriveEvidenceID(req evidenceRecordRequest) (checksum, evidenceID string) {
	payload := map[string]interface{}{
		"meta":           req.Meta,
		"eventType":      strings.TrimSpace(req.EventType),
		"eventId":        strings.TrimSpace(req.EventID),
		"runId":          strings.TrimSpace(req.RunID),
		"stage":          strings.TrimSpace(req.Stage),
		"payload":        req.Payload,
		"retentionClass": strings.TrimSpace(req.RetentionClass),
	}
	checksum = sha256JSON(payload)
	evidenceID = "evd_" + shortHex(strings.TrimPrefix(checksum, "sha256:"), 24)
	return checksum, evidenceID
}

func normalizeIDs(ids []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func buildBundleHint(req evidenceRecordRequest) string {
	if strings.TrimSpace(req.RunID) != "" {
		return "run:" + strings.TrimSpace(req.RunID)
	}
	if strings.TrimSpace(req.Stage) != "" {
		return "stage:" + strings.TrimSpace(req.Stage)
	}
	return "event:" + strings.TrimSpace(req.EventType)
}

func sha256JSON(v interface{}) string {
	b, _ := json.Marshal(v)
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func shortHex(v string, n int) string {
	if len(v) <= n {
		return v
	}
	return v[:n]
}

func asString(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	default:
		return ""
	}
}

func containsString(items []string, target string) bool {
	for _, item := range items {
		if strings.EqualFold(strings.TrimSpace(item), strings.TrimSpace(target)) {
			return true
		}
	}
	return false
}

func joinURIPath(base string, parts ...string) string {
	base = strings.TrimRight(base, "/")
	segments := []string{base}
	for _, p := range parts {
		p = strings.Trim(p, "/")
		if p != "" {
			segments = append(segments, p)
		}
	}
	return strings.Join(segments, "/")
}

func (s *server) authorize(w http.ResponseWriter, r *http.Request) bool {
	if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
		http.Error(w, "client certificate required", http.StatusUnauthorized)
		return false
	}
	if !s.cfg.RequireBearer {
		return true
	}
	got := strings.TrimSpace(r.Header.Get("Authorization"))
	want := "Bearer " + s.bearerToken
	if got != want {
		http.Error(w, "invalid bearer token", http.StatusUnauthorized)
		return false
	}
	return true
}

func writeProviderError(w http.ResponseWriter, code int, errCode, msg string, retryable bool, details map[string]interface{}) {
	writeJSON(w, code, providerError{
		ErrorCode: errCode,
		Message:   msg,
		Retryable: retryable,
		Details:   details,
	})
}

func (s *server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s remote=%s dur=%s", r.Method, r.URL.Path, r.RemoteAddr, time.Since(start).Round(time.Millisecond))
	})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
