package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type JSONObject map[string]interface{}

type Config struct {
	ProviderID      string   `json:"providerId"`
	ProviderVersion string   `json:"providerVersion"`
	OPABaseURL      string   `json:"opaBaseUrl"`
	OPADecisionPath string   `json:"opaDecisionPath"`
	OPAHealthPath   string   `json:"opaHealthPath"`
	TimeoutSeconds  int      `json:"timeoutSeconds"`
	Capabilities    []string `json:"capabilities"`
	PolicyBundle    struct {
		PolicyID      string `json:"policyId"`
		PolicyVersion string `json:"policyVersion"`
		Checksum      string `json:"checksum"`
	} `json:"policyBundle"`
}

type ProviderCapabilitiesResponse struct {
	ProviderType    string                 `json:"providerType"`
	ProviderID      string                 `json:"providerId"`
	ContractVersion string                 `json:"contractVersion"`
	ProviderVersion string                 `json:"providerVersion,omitempty"`
	Capabilities    []string               `json:"capabilities"`
	Status          map[string]interface{} `json:"status,omitempty"`
}

type ProviderError struct {
	ErrorCode string                 `json:"errorCode"`
	Message   string                 `json:"message"`
	Retryable bool                   `json:"retryable"`
	Details   map[string]interface{} `json:"details,omitempty"`
}

type DecisionReason struct {
	Code    string                 `json:"code,omitempty"`
	Message string                 `json:"message,omitempty"`
	Details map[string]interface{} `json:"details,omitempty"`
}

type Obligation struct {
	Type   string                 `json:"type"`
	Config map[string]interface{} `json:"config,omitempty"`
}

type PolicyEvaluateRequest struct {
	Meta     JSONObject `json:"meta"`
	Profile  JSONObject `json:"profile,omitempty"`
	Subject  JSONObject `json:"subject"`
	Action   JSONObject `json:"action"`
	Resource JSONObject `json:"resource,omitempty"`
	Context  JSONObject `json:"context,omitempty"`
	Mode     string     `json:"mode,omitempty"`
	DryRun   bool       `json:"dryRun,omitempty"`
}

type PolicyEvaluateResponse struct {
	Decision     string           `json:"decision"`
	GrantToken   string           `json:"grantToken,omitempty"`
	Reasons      []DecisionReason `json:"reasons,omitempty"`
	Obligations  []Obligation     `json:"obligations,omitempty"`
	PolicyBundle *PolicyBundleRef `json:"policyBundle,omitempty"`
	EvidenceRefs []string         `json:"evidenceRefs,omitempty"`
	Output       JSONObject       `json:"output,omitempty"`
}

type PolicyBundleRef struct {
	PolicyID      string `json:"policyId,omitempty"`
	PolicyVersion string `json:"policyVersion,omitempty"`
	Checksum      string `json:"checksum,omitempty"`
}

type PolicyBundleValidationRequest struct {
	Meta                 JSONObject `json:"meta"`
	Bundle               JSONObject `json:"bundle"`
	ExpectedCapabilities []string   `json:"expectedCapabilities,omitempty"`
}

type PolicyBundleValidationResponse struct {
	Valid                  bool             `json:"valid"`
	Errors                 []DecisionReason `json:"errors,omitempty"`
	Warnings               []DecisionReason `json:"warnings,omitempty"`
	DiscoveredCapabilities []string         `json:"discoveredCapabilities,omitempty"`
}

type opaEnvelope struct {
	Result json.RawMessage `json:"result"`
}

type Server struct {
	cfg        Config
	httpClient *http.Client
}

func main() {
	var (
		listenAddr = flag.String("listen", ":8080", "HTTP listen address")
		configPath = flag.String("config", "providers/policy/opa-adapter/config.example.json", "path to JSON config")
	)
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	applyDefaults(&cfg)

	s := &Server{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: time.Duration(cfg.TimeoutSeconds) * time.Second,
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1alpha1/capabilities", s.handleCapabilities)
	mux.HandleFunc("/v1alpha1/policy-provider/evaluate", s.handleEvaluate)
	mux.HandleFunc("/v1alpha1/policy-provider/validate-bundle", s.handleValidateBundle)

	server := &http.Server{
		Addr:              *listenAddr,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("policy provider (OPA adapter) listening on %s (providerId=%s, opa=%s%s)", *listenAddr, cfg.ProviderID, cfg.OPABaseURL, cfg.OPADecisionPath)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen: %v", err)
	}
}

func loadConfig(path string) (Config, error) {
	var cfg Config
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func applyDefaults(cfg *Config) {
	if cfg.ProviderID == "" {
		cfg.ProviderID = "oss-policy-opa"
	}
	if cfg.ProviderVersion == "" {
		cfg.ProviderVersion = "0.1.0"
	}
	if cfg.OPABaseURL == "" {
		cfg.OPABaseURL = "http://127.0.0.1:8181"
	}
	if cfg.OPADecisionPath == "" {
		cfg.OPADecisionPath = "/v1/data/epydios/policy/evaluate"
	}
	if cfg.OPAHealthPath == "" {
		cfg.OPAHealthPath = "/health"
	}
	if cfg.TimeoutSeconds <= 0 {
		cfg.TimeoutSeconds = 5
	}
	if len(cfg.Capabilities) == 0 {
		cfg.Capabilities = []string{
			"policy.evaluate",
			"policy.validate_bundle",
			"audit_mode",
			"opa.delegate",
		}
	}
	if cfg.PolicyBundle.PolicyID == "" {
		cfg.PolicyBundle.PolicyID = "EPYDIOS_OSS_POLICY_BASELINE"
	}
	if cfg.PolicyBundle.PolicyVersion == "" {
		cfg.PolicyBundle.PolicyVersion = "v1"
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.checkOPAHealth(ctx); err != nil {
		writeProviderError(w, http.StatusServiceUnavailable, "OPA_UNAVAILABLE", "OPA health check failed", true, map[string]interface{}{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	resp := ProviderCapabilitiesResponse{
		ProviderType:    "PolicyProvider",
		ProviderID:      s.cfg.ProviderID,
		ContractVersion: "v1alpha1",
		ProviderVersion: s.cfg.ProviderVersion,
		Capabilities:    s.cfg.Capabilities,
		Status: map[string]interface{}{
			"backend":         "opa",
			"opaBaseURL":      s.cfg.OPABaseURL,
			"opaDecisionPath": s.cfg.OPADecisionPath,
		},
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	defer r.Body.Close()
	var req PolicyEvaluateRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validatePolicyEvaluateRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}
	if req.Mode == "" {
		req.Mode = "enforce"
	}

	resp, err := s.evaluateWithOPA(r.Context(), req)
	if err != nil {
		writeProviderError(w, http.StatusInternalServerError, "OPA_EVALUATION_FAILED", "OPA evaluation failed", true, map[string]interface{}{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleValidateBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	defer r.Body.Close()
	var req PolicyBundleValidationRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if req.Meta == nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", "meta is required", false, nil)
		return
	}
	if req.Bundle == nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", "bundle is required", false, nil)
		return
	}

	resp := PolicyBundleValidationResponse{
		Valid:                  true,
		DiscoveredCapabilities: append([]string(nil), s.cfg.Capabilities...),
	}

	var errs []DecisionReason
	if strings.TrimSpace(asString(req.Bundle["policyId"])) == "" {
		errs = append(errs, DecisionReason{
			Code:    "POLICY_ID_REQUIRED",
			Message: "bundle.policyId is required for the OSS OPA adapter baseline",
		})
	}
	if strings.TrimSpace(asString(req.Bundle["policyVersion"])) == "" {
		errs = append(errs, DecisionReason{
			Code:    "POLICY_VERSION_REQUIRED",
			Message: "bundle.policyVersion is required for the OSS OPA adapter baseline",
		})
	}

	for _, cap := range req.ExpectedCapabilities {
		if !containsString(s.cfg.Capabilities, cap) {
			errs = append(errs, DecisionReason{
				Code:    "UNSUPPORTED_CAPABILITY",
				Message: fmt.Sprintf("expected capability %q is not supported", cap),
				Details: map[string]interface{}{"capability": cap},
			})
		}
	}

	if len(errs) > 0 {
		resp.Valid = false
		resp.Errors = errs
	}
	writeJSON(w, http.StatusOK, resp)
}

func validatePolicyEvaluateRequest(req PolicyEvaluateRequest) error {
	if req.Meta == nil {
		return fmt.Errorf("meta is required")
	}
	if strings.TrimSpace(asString(req.Meta["requestId"])) == "" {
		return fmt.Errorf("meta.requestId is required")
	}
	if strings.TrimSpace(asString(req.Meta["timestamp"])) == "" {
		return fmt.Errorf("meta.timestamp is required")
	}
	if req.Subject == nil {
		return fmt.Errorf("subject is required")
	}
	if strings.TrimSpace(asString(req.Subject["type"])) == "" {
		return fmt.Errorf("subject.type is required")
	}
	if strings.TrimSpace(asString(req.Subject["id"])) == "" {
		return fmt.Errorf("subject.id is required")
	}
	if req.Action == nil {
		return fmt.Errorf("action is required")
	}
	if strings.TrimSpace(asString(req.Action["verb"])) == "" {
		return fmt.Errorf("action.verb is required")
	}
	return nil
}

func (s *Server) checkOPAHealth(ctx context.Context) error {
	u, err := joinURL(s.cfg.OPABaseURL, s.cfg.OPAHealthPath)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("opa health status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

func (s *Server) evaluateWithOPA(ctx context.Context, req PolicyEvaluateRequest) (PolicyEvaluateResponse, error) {
	var out PolicyEvaluateResponse

	body, err := json.Marshal(map[string]interface{}{"input": req})
	if err != nil {
		return out, err
	}

	u, err := joinURL(s.cfg.OPABaseURL, s.cfg.OPADecisionPath)
	if err != nil {
		return out, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return out, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(httpReq)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return out, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return out, fmt.Errorf("opa decision status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var env opaEnvelope
	if err := json.Unmarshal(respBody, &env); err != nil {
		return out, fmt.Errorf("decode opa response: %w", err)
	}
	if len(env.Result) == 0 || string(env.Result) == "null" {
		return out, fmt.Errorf("opa response missing result")
	}

	parsed, err := parsePolicyDecision(env.Result)
	if err != nil {
		return out, err
	}

	// Attach default bundle metadata if the backend did not provide any.
	if parsed.PolicyBundle == nil {
		parsed.PolicyBundle = &PolicyBundleRef{
			PolicyID:      s.cfg.PolicyBundle.PolicyID,
			PolicyVersion: s.cfg.PolicyBundle.PolicyVersion,
			Checksum:      s.cfg.PolicyBundle.Checksum,
		}
	}
	if parsed.Output == nil {
		parsed.Output = JSONObject{}
	}
	if _, exists := parsed.Output["providerId"]; !exists {
		parsed.Output["providerId"] = s.cfg.ProviderID
	}
	if _, exists := parsed.Output["backend"]; !exists {
		parsed.Output["backend"] = "opa"
	}

	return parsed, nil
}

func parsePolicyDecision(raw json.RawMessage) (PolicyEvaluateResponse, error) {
	var out PolicyEvaluateResponse
	var obj map[string]interface{}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return out, fmt.Errorf("decode opa result object: %w", err)
	}

	decision := strings.ToUpper(strings.TrimSpace(asString(obj["decision"])))
	if decision == "" {
		if allow, ok := obj["allow"].(bool); ok {
			if allow {
				decision = "ALLOW"
			} else {
				decision = "DENY"
			}
		}
	}
	if !isValidDecision(decision) {
		return out, fmt.Errorf("opa result returned invalid or missing decision")
	}
	out.Decision = decision

	if arr, ok := obj["reasons"].([]interface{}); ok {
		out.Reasons = decodeDecisionReasons(arr)
	}
	if arr, ok := obj["obligations"].([]interface{}); ok {
		out.Obligations = decodeObligations(arr)
	}
	if arr, ok := obj["evidenceRefs"].([]interface{}); ok {
		for _, item := range arr {
			if s := strings.TrimSpace(asString(item)); s != "" {
				out.EvidenceRefs = append(out.EvidenceRefs, s)
			}
		}
	}
	if token := strings.TrimSpace(asString(obj["grantToken"])); token != "" {
		out.GrantToken = token
	}
	if out.GrantToken == "" {
		if token := strings.TrimSpace(asString(obj["grant_token"])); token != "" {
			out.GrantToken = token
		}
	}
	if m, ok := obj["output"].(map[string]interface{}); ok {
		out.Output = JSONObject(m)
		if out.GrantToken == "" {
			for _, candidate := range []string{"grantToken", "grant_token", "aimxsGrantToken", "aimxs_grant_token"} {
				if token := strings.TrimSpace(asString(m[candidate])); token != "" {
					out.GrantToken = token
					break
				}
			}
		}
	}
	if m, ok := obj["policyBundle"].(map[string]interface{}); ok {
		out.PolicyBundle = &PolicyBundleRef{
			PolicyID:      asString(m["policyId"]),
			PolicyVersion: asString(m["policyVersion"]),
			Checksum:      asString(m["checksum"]),
		}
	}

	if len(out.Reasons) == 0 {
		switch out.Decision {
		case "ALLOW":
			out.Reasons = []DecisionReason{{Code: "ALLOW", Message: "Allowed by policy evaluation."}}
		case "DENY":
			out.Reasons = []DecisionReason{{Code: "DENY", Message: "Denied by policy evaluation."}}
		case "CHALLENGE":
			out.Reasons = []DecisionReason{{Code: "CHALLENGE", Message: "Challenge required by policy evaluation."}}
		case "DEFER":
			out.Reasons = []DecisionReason{{Code: "DEFER", Message: "Deferred by policy evaluation."}}
		}
	}

	return out, nil
}

func decodeDecisionReasons(arr []interface{}) []DecisionReason {
	var out []DecisionReason
	for _, item := range arr {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		reason := DecisionReason{
			Code:    asString(m["code"]),
			Message: asString(m["message"]),
		}
		if details, ok := m["details"].(map[string]interface{}); ok {
			reason.Details = details
		}
		out = append(out, reason)
	}
	return out
}

func decodeObligations(arr []interface{}) []Obligation {
	var out []Obligation
	for _, item := range arr {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		ob := Obligation{
			Type: asString(m["type"]),
		}
		if cfg, ok := m["config"].(map[string]interface{}); ok {
			ob.Config = cfg
		}
		if strings.TrimSpace(ob.Type) == "" {
			continue
		}
		out = append(out, ob)
	}
	return out
}

func joinURL(baseURL, path string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	if path == "" {
		return u.String(), nil
	}
	u.Path = joinURLPath(u.Path, path)
	return u.String(), nil
}

func joinURLPath(basePath, subPath string) string {
	switch {
	case basePath == "":
		if strings.HasPrefix(subPath, "/") {
			return subPath
		}
		return "/" + subPath
	case strings.HasSuffix(basePath, "/") && strings.HasPrefix(subPath, "/"):
		return basePath + strings.TrimPrefix(subPath, "/")
	case !strings.HasSuffix(basePath, "/") && !strings.HasPrefix(subPath, "/"):
		return basePath + "/" + subPath
	default:
		return basePath + subPath
	}
}

func asString(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	case fmt.Stringer:
		return x.String()
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

func isValidDecision(v string) bool {
	switch v {
	case "ALLOW", "DENY", "CHALLENGE", "DEFER":
		return true
	default:
		return false
	}
}

func writeProviderError(w http.ResponseWriter, code int, errCode, msg string, retryable bool, details map[string]interface{}) {
	writeJSON(w, code, ProviderError{
		ErrorCode: errCode,
		Message:   msg,
		Retryable: retryable,
		Details:   details,
	})
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s remote=%s dur=%s", r.Method, r.URL.Path, r.RemoteAddr, time.Since(start).Round(time.Millisecond))
	})
}
