package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type JSONObject map[string]interface{}

type Config struct {
	ProviderID            string   `json:"providerId"`
	ProviderVersion       string   `json:"providerVersion"`
	StorageURIBase        string   `json:"storageUriBase"`
	BundleManifestURIBase string   `json:"bundleManifestUriBase"`
	Capabilities          []string `json:"capabilities"`
	DefaultRetentionClass string   `json:"defaultRetentionClass"`
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

type EvidenceRecordRequest struct {
	Meta           JSONObject   `json:"meta"`
	EventType      string       `json:"eventType"`
	EventID        string       `json:"eventId,omitempty"`
	RunID          string       `json:"runId,omitempty"`
	Stage          string       `json:"stage,omitempty"`
	Payload        JSONObject   `json:"payload,omitempty"`
	ArtifactRefs   []JSONObject `json:"artifactRefs,omitempty"`
	RetentionClass string       `json:"retentionClass,omitempty"`
}

type EvidenceRecordResponse struct {
	Accepted  bool   `json:"accepted"`
	EvidenceID string `json:"evidenceId"`
	Checksum  string `json:"checksum,omitempty"`
	StorageURI string `json:"storageUri,omitempty"`
	BundleHint string `json:"bundleHint,omitempty"`
}

type EvidenceFinalizeBundleRequest struct {
	Meta           JSONObject `json:"meta"`
	BundleID       string     `json:"bundleId"`
	RunID          string     `json:"runId,omitempty"`
	EvidenceIDs    []string   `json:"evidenceIds,omitempty"`
	RetentionClass string     `json:"retentionClass,omitempty"`
	Annotations    JSONObject `json:"annotations,omitempty"`
}

type EvidenceFinalizeBundleResponse struct {
	BundleID         string `json:"bundleId"`
	ManifestURI      string `json:"manifestUri"`
	ManifestChecksum string `json:"manifestChecksum,omitempty"`
	ItemCount        int    `json:"itemCount,omitempty"`
}

type storedEvidence struct {
	EvidenceID      string
	RunID           string
	RetentionClass  string
	EventType       string
	CreatedAt       time.Time
	Checksum        string
	StorageURI      string
}

type Server struct {
	cfg Config

	mu       sync.RWMutex
	evidence map[string]storedEvidence
}

func main() {
	var (
		listenAddr = flag.String("listen", ":8080", "HTTP listen address")
		configPath = flag.String("config", "providers/evidence/memory/config.example.json", "path to JSON config")
	)
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	applyDefaults(&cfg)

	s := &Server{
		cfg:      cfg,
		evidence: make(map[string]storedEvidence),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1alpha1/capabilities", s.handleCapabilities)
	mux.HandleFunc("/v1alpha1/evidence-provider/record", s.handleRecord)
	mux.HandleFunc("/v1alpha1/evidence-provider/finalize-bundle", s.handleFinalizeBundle)

	server := &http.Server{
		Addr:              *listenAddr,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("evidence provider (memory) listening on %s (providerId=%s)", *listenAddr, cfg.ProviderID)
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
		cfg.ProviderID = "oss-evidence-memory"
	}
	if cfg.ProviderVersion == "" {
		cfg.ProviderVersion = "0.2.0"
	}
	if cfg.StorageURIBase == "" {
		cfg.StorageURIBase = "memory://epydios-oss-evidence"
	}
	if cfg.BundleManifestURIBase == "" {
		cfg.BundleManifestURIBase = cfg.StorageURIBase + "/bundles"
	}
	if len(cfg.Capabilities) == 0 {
		cfg.Capabilities = []string{
			"evidence.record",
			"evidence.finalize_bundle",
			"retention.basic",
		}
	}
	if cfg.DefaultRetentionClass == "" {
		cfg.DefaultRetentionClass = "standard"
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}
	s.mu.RLock()
	count := len(s.evidence)
	s.mu.RUnlock()
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":        "ok",
		"storedRecords": count,
	})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	s.mu.RLock()
	count := len(s.evidence)
	s.mu.RUnlock()

	resp := ProviderCapabilitiesResponse{
		ProviderType:    "EvidenceProvider",
		ProviderID:      s.cfg.ProviderID,
		ContractVersion: "v1alpha1",
		ProviderVersion: s.cfg.ProviderVersion,
		Capabilities:    s.cfg.Capabilities,
		Status: map[string]interface{}{
			"backend":              "memory",
			"storedRecordCount":    count,
			"storageUriBase":       s.cfg.StorageURIBase,
			"bundleManifestUriBase": s.cfg.BundleManifestURIBase,
		},
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleRecord(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	defer r.Body.Close()
	var req EvidenceRecordRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateEvidenceRecordRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	createdAt := time.Now().UTC()
	checksum, evidenceID := deriveEvidenceChecksumAndID(req)
	retentionClass := strings.TrimSpace(req.RetentionClass)
	if retentionClass == "" {
		retentionClass = s.cfg.DefaultRetentionClass
	}
	storageURI := joinURIPath(s.cfg.StorageURIBase, "evidence", evidenceID+".json")

	s.mu.Lock()
	s.evidence[evidenceID] = storedEvidence{
		EvidenceID:     evidenceID,
		RunID:          strings.TrimSpace(req.RunID),
		RetentionClass: retentionClass,
		EventType:      strings.TrimSpace(req.EventType),
		CreatedAt:      createdAt,
		Checksum:       checksum,
		StorageURI:     storageURI,
	}
	s.mu.Unlock()

	resp := EvidenceRecordResponse{
		Accepted:   true,
		EvidenceID: evidenceID,
		Checksum:   checksum,
		StorageURI: storageURI,
		BundleHint: buildBundleHint(req),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleFinalizeBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeProviderError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	defer r.Body.Close()
	var req EvidenceFinalizeBundleRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	if err := validateEvidenceFinalizeBundleRequest(req); err != nil {
		writeProviderError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), false, nil)
		return
	}

	itemCount, resolvedIDs := s.resolveFinalizeItems(req)

	manifestPayload := map[string]interface{}{
		"providerId":      s.cfg.ProviderID,
		"bundleId":        strings.TrimSpace(req.BundleID),
		"runId":           strings.TrimSpace(req.RunID),
		"retentionClass":  coalesce(strings.TrimSpace(req.RetentionClass), s.cfg.DefaultRetentionClass),
		"evidenceIds":     resolvedIDs,
		"annotations":     mapOrEmpty(req.Annotations),
		"itemCount":       itemCount,
		"finalizedAt":     time.Now().UTC().Format(time.RFC3339),
	}
	manifestChecksum := sha256JSON(manifestPayload)
	manifestURI := joinURIPath(s.cfg.BundleManifestURIBase, strings.TrimSpace(req.BundleID)+".json")

	resp := EvidenceFinalizeBundleResponse{
		BundleID:         strings.TrimSpace(req.BundleID),
		ManifestURI:      manifestURI,
		ManifestChecksum: manifestChecksum,
		ItemCount:        itemCount,
	}
	writeJSON(w, http.StatusOK, resp)
}

func validateEvidenceRecordRequest(req EvidenceRecordRequest) error {
	if req.Meta == nil {
		return fmt.Errorf("meta is required")
	}
	if strings.TrimSpace(asString(req.Meta["requestId"])) == "" {
		return fmt.Errorf("meta.requestId is required")
	}
	if strings.TrimSpace(asString(req.Meta["timestamp"])) == "" {
		return fmt.Errorf("meta.timestamp is required")
	}
	if strings.TrimSpace(req.EventType) == "" {
		return fmt.Errorf("eventType is required")
	}
	return nil
}

func validateEvidenceFinalizeBundleRequest(req EvidenceFinalizeBundleRequest) error {
	if req.Meta == nil {
		return fmt.Errorf("meta is required")
	}
	if strings.TrimSpace(asString(req.Meta["requestId"])) == "" {
		return fmt.Errorf("meta.requestId is required")
	}
	if strings.TrimSpace(asString(req.Meta["timestamp"])) == "" {
		return fmt.Errorf("meta.timestamp is required")
	}
	if strings.TrimSpace(req.BundleID) == "" {
		return fmt.Errorf("bundleId is required")
	}
	return nil
}

func deriveEvidenceChecksumAndID(req EvidenceRecordRequest) (checksum, evidenceID string) {
	payload := map[string]interface{}{
		"meta":           mapOrEmpty(req.Meta),
		"eventType":      strings.TrimSpace(req.EventType),
		"eventId":        strings.TrimSpace(req.EventID),
		"runId":          strings.TrimSpace(req.RunID),
		"stage":          strings.TrimSpace(req.Stage),
		"payload":        mapOrEmpty(req.Payload),
		"artifactRefs":   req.ArtifactRefs,
		"retentionClass": strings.TrimSpace(req.RetentionClass),
	}

	checksum = sha256JSON(payload)
	evidenceID = "evd_" + shortHex(strings.TrimPrefix(checksum, "sha256:"), 24)
	return checksum, evidenceID
}

func (s *Server) resolveFinalizeItems(req EvidenceFinalizeBundleRequest) (int, []string) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(req.EvidenceIDs) > 0 {
		ids := normalizeAndSortIDs(req.EvidenceIDs)
		return len(ids), ids
	}

	if strings.TrimSpace(req.RunID) == "" {
		return 0, nil
	}

	var ids []string
	for _, rec := range s.evidence {
		if rec.RunID == strings.TrimSpace(req.RunID) {
			ids = append(ids, rec.EvidenceID)
		}
	}
	sort.Strings(ids)
	return len(ids), ids
}

func buildBundleHint(req EvidenceRecordRequest) string {
	if strings.TrimSpace(req.RunID) != "" {
		return "run:" + strings.TrimSpace(req.RunID)
	}
	if strings.TrimSpace(req.Stage) != "" {
		return "stage:" + strings.TrimSpace(req.Stage)
	}
	return "event:" + strings.TrimSpace(req.EventType)
}

func normalizeAndSortIDs(ids []string) []string {
	seen := map[string]struct{}{}
	var out []string
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

func coalesce(v, d string) string {
	if strings.TrimSpace(v) != "" {
		return v
	}
	return d
}

func mapOrEmpty(m JSONObject) map[string]interface{} {
	if m == nil {
		return map[string]interface{}{}
	}
	return m
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

