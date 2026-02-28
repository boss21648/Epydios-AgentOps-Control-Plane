package main

import (
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type Config struct {
	ProviderID            string `json:"providerId"`
	ProviderVersion       string `json:"providerVersion"`
	DefaultProfileID      string `json:"defaultProfileId"`
	DefaultProfileVersion string `json:"defaultProfileVersion"`
	TTLSeconds            int    `json:"ttlSeconds"`
	Rules                 []Rule `json:"rules"`
}

type Rule struct {
	TenantID        string `json:"tenantId"`
	ProjectID       string `json:"projectId"`
	Environment     string `json:"environment"`
	TaskKind        string `json:"taskKind"`
	TaskSensitivity string `json:"taskSensitivity"`
	ProfileID       string `json:"profileId"`
	ProfileVersion  string `json:"profileVersion"`
	Source          string `json:"source"`
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

type ProfileResolveRequest struct {
	Meta struct {
		RequestID   string `json:"requestId"`
		TenantID    string `json:"tenantId"`
		ProjectID   string `json:"projectId"`
		Environment string `json:"environment"`
	} `json:"meta"`
	Task struct {
		Kind         string `json:"kind"`
		Sensitivity  string `json:"sensitivity"`
		LatencyClass string `json:"latencyClass"`
	} `json:"task"`
	Defaults struct {
		ProfileID string `json:"profileId"`
	} `json:"defaults"`
	Context map[string]interface{} `json:"context"`
}

type ProfileResolveResponse struct {
	ProfileID            string                 `json:"profileId"`
	ProfileVersion       string                 `json:"profileVersion,omitempty"`
	Source               string                 `json:"source,omitempty"`
	TTLSeconds           int                    `json:"ttlSeconds,omitempty"`
	Attributes           map[string]interface{} `json:"attributes,omitempty"`
	RequiredCapabilities []string               `json:"requiredCapabilities,omitempty"`
}

type Server struct {
	cfg Config
}

func main() {
	var (
		listenAddr = flag.String("listen", ":8080", "HTTP listen address")
		configPath = flag.String("config", "providers/profile/static-resolver/config.example.json", "path to JSON config")
	)
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	if cfg.ProviderID == "" {
		cfg.ProviderID = "oss-profile-static"
	}
	if cfg.ProviderVersion == "" {
		cfg.ProviderVersion = "0.1.0"
	}
	if cfg.DefaultProfileID == "" {
		cfg.DefaultProfileID = "EPYDIOS_PROFILE_BASELINE_V1"
	}
	if cfg.DefaultProfileVersion == "" {
		cfg.DefaultProfileVersion = "v1"
	}
	if cfg.TTLSeconds <= 0 {
		cfg.TTLSeconds = 300
	}

	s := &Server{cfg: cfg}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1alpha1/capabilities", s.handleCapabilities)
	mux.HandleFunc("/v1alpha1/profile-resolver/resolve", s.handleResolve)

	server := &http.Server{
		Addr:              *listenAddr,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("profile resolver provider listening on %s (providerId=%s)", *listenAddr, cfg.ProviderID)
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

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
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
		ProviderType:    "ProfileResolver",
		ProviderID:      s.cfg.ProviderID,
		ContractVersion: "v1alpha1",
		ProviderVersion: s.cfg.ProviderVersion,
		Capabilities: []string{
			"profile.resolve",
			"tenant-defaults",
			"environment-overrides",
			"task-sensitivity-routing",
		},
		Status: map[string]interface{}{
			"ruleCount": len(s.cfg.Rules),
		},
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	defer r.Body.Close()
	var req ProfileResolveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}

	profileID, profileVersion, source := s.resolve(req)
	resp := ProfileResolveResponse{
		ProfileID:      profileID,
		ProfileVersion: profileVersion,
		Source:         source,
		TTLSeconds:     s.cfg.TTLSeconds,
		Attributes: map[string]interface{}{
			"providerId": s.cfg.ProviderID,
			"requestId":  req.Meta.RequestID,
		},
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) resolve(req ProfileResolveRequest) (profileID, profileVersion, source string) {
	for _, rule := range s.cfg.Rules {
		if !matches(rule.TenantID, req.Meta.TenantID) {
			continue
		}
		if !matches(rule.ProjectID, req.Meta.ProjectID) {
			continue
		}
		if !matches(rule.Environment, req.Meta.Environment) {
			continue
		}
		if !matches(rule.TaskKind, req.Task.Kind) {
			continue
		}
		if !matches(rule.TaskSensitivity, req.Task.Sensitivity) {
			continue
		}
		return coalesce(rule.ProfileID, s.cfg.DefaultProfileID), coalesce(rule.ProfileVersion, s.cfg.DefaultProfileVersion), coalesce(rule.Source, "static-rule")
	}

	if req.Defaults.ProfileID != "" {
		return req.Defaults.ProfileID, s.cfg.DefaultProfileVersion, "request-default"
	}
	return s.cfg.DefaultProfileID, s.cfg.DefaultProfileVersion, "static-default"
}

func matches(ruleValue, actual string) bool {
	if ruleValue == "" {
		return true
	}
	return strings.EqualFold(strings.TrimSpace(ruleValue), strings.TrimSpace(actual))
}

func coalesce(v, d string) string {
	if strings.TrimSpace(v) != "" {
		return v
	}
	return d
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
