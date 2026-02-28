package runtime

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type APIServer struct {
	store        RunStore
	orchestrator *Orchestrator
	auth         *AuthEnforcer
}

func NewAPIServer(store RunStore, orchestrator *Orchestrator, auth *AuthEnforcer) *APIServer {
	return &APIServer{
		store:        store,
		orchestrator: orchestrator,
		auth:         auth,
	}
}

func (s *APIServer) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/v1alpha1/runtime/runs", s.handleRuns)
	mux.HandleFunc("/v1alpha1/runtime/runs/", s.handleRunByID)
	mux.HandleFunc("/v1alpha1/runtime/audit/events", s.handleAuditEvents)
	return loggingMiddleware(mux)
}

func (s *APIServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	if err := s.store.Ping(ctx); err != nil {
		writeAPIError(w, http.StatusServiceUnavailable, "STORE_UNAVAILABLE", "run store unavailable", true, map[string]interface{}{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "ok",
		"time":   time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *APIServer) handleRuns(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		ctx, ok := s.authorizeRequest(w, r, PermissionRunCreate)
		if !ok {
			return
		}
		s.handleCreateRun(w, r.WithContext(ctx))
	case http.MethodGet:
		ctx, ok := s.authorizeRequest(w, r, PermissionRunRead)
		if !ok {
			return
		}
		s.handleListRuns(w, r.WithContext(ctx))
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
	}
}

func (s *APIServer) handleCreateRun(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()

	var req RunCreateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body", false, map[string]interface{}{"error": err.Error()})
		return
	}
	identity, _ := RuntimeIdentityFromContext(r.Context())
	if err := enforceRequestMetaScope(&req.Meta, identity); err != nil {
		emitAuditEvent(r.Context(), "runtime.scope.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": PermissionRunCreate,
			"tenantId":   req.Meta.TenantID,
			"projectId":  req.Meta.ProjectID,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return
	}
	if err := s.authorizeScoped(identity, PermissionRunCreate, req.Meta.TenantID, req.Meta.ProjectID); err != nil {
		emitAuditEvent(r.Context(), "runtime.authz.policy.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": PermissionRunCreate,
			"tenantId":   req.Meta.TenantID,
			"projectId":  req.Meta.ProjectID,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return
	}
	emitAuditEvent(r.Context(), "runtime.authz.policy.allow", map[string]interface{}{
		"path":       r.URL.Path,
		"method":     r.Method,
		"permission": PermissionRunCreate,
		"tenantId":   req.Meta.TenantID,
		"projectId":  req.Meta.ProjectID,
	})

	injectActorIdentity(&req.Meta, r.Context())
	emitAuditEvent(r.Context(), "runtime.scope.allow", map[string]interface{}{
		"path":       r.URL.Path,
		"method":     r.Method,
		"permission": PermissionRunCreate,
		"tenantId":   req.Meta.TenantID,
		"projectId":  req.Meta.ProjectID,
	})

	run, err := s.orchestrator.ExecuteRun(r.Context(), req)
	if err != nil {
		emitAuditEvent(r.Context(), "runtime.run.create.failed", map[string]interface{}{
			"requestId": req.Meta.RequestID,
			"tenantId":  req.Meta.TenantID,
			"projectId": req.Meta.ProjectID,
			"error":     err.Error(),
		})
		details := map[string]interface{}{"error": err.Error()}
		if run != nil && run.RunID != "" {
			details["runId"] = run.RunID
		}
		writeAPIError(w, http.StatusInternalServerError, "RUN_EXECUTION_FAILED", "run execution failed", true, details)
		return
	}
	emitAuditEvent(r.Context(), "runtime.run.create.accepted", map[string]interface{}{
		"runId":       run.RunID,
		"requestId":   run.RequestID,
		"tenantId":    run.TenantID,
		"projectId":   run.ProjectID,
		"status":      run.Status,
		"policy":      run.PolicyDecision,
		"profileRef":  run.SelectedProfileProvider,
		"policyRef":   run.SelectedPolicyProvider,
		"evidenceRef": run.SelectedEvidenceProvider,
	})
	writeJSON(w, http.StatusCreated, run)
}

func (s *APIServer) handleListRuns(w http.ResponseWriter, r *http.Request) {
	limit := 25
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeAPIError(w, http.StatusBadRequest, "INVALID_LIMIT", "limit must be an integer", false, map[string]interface{}{"limit": raw})
			return
		}
		limit = parsed
	}

	items, err := s.store.ListRuns(r.Context(), limit)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "STORE_QUERY_FAILED", "failed to list runs", true, map[string]interface{}{"error": err.Error()})
		return
	}

	identity, _ := RuntimeIdentityFromContext(r.Context())
	filtered, deniedByAuthz := filterRunSummariesByAuthorization(items, identity, s.auth, PermissionRunRead)
	emitAuditEvent(r.Context(), "runtime.run.list", map[string]interface{}{
		"path":            r.URL.Path,
		"method":          r.Method,
		"requestedLimit":  limit,
		"returnedCount":   len(filtered),
		"unfilteredCount": len(items),
		"filteredDenied":  deniedByAuthz,
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"count": len(filtered),
		"items": filtered,
	})
}

func (s *APIServer) handleRunByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}
	ctx, ok := s.authorizeRequest(w, r, PermissionRunRead)
	if !ok {
		return
	}
	r = r.WithContext(ctx)

	runID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/v1alpha1/runtime/runs/"))
	if runID == "" {
		writeAPIError(w, http.StatusBadRequest, "INVALID_RUN_ID", "runId is required", false, nil)
		return
	}

	run, err := s.store.GetRun(r.Context(), runID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeAPIError(w, http.StatusNotFound, "RUN_NOT_FOUND", "run not found", false, map[string]interface{}{"runId": runID})
			return
		}
		writeAPIError(w, http.StatusInternalServerError, "STORE_QUERY_FAILED", "failed to fetch run", true, map[string]interface{}{"error": err.Error(), "runId": runID})
		return
	}

	identity, _ := RuntimeIdentityFromContext(r.Context())
	if err := enforceRunRecordScope(run.TenantID, run.ProjectID, identity); err != nil {
		emitAuditEvent(r.Context(), "runtime.scope.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": PermissionRunRead,
			"runId":      runID,
			"tenantId":   run.TenantID,
			"projectId":  run.ProjectID,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return
	}
	if err := s.authorizeScoped(identity, PermissionRunRead, run.TenantID, run.ProjectID); err != nil {
		emitAuditEvent(r.Context(), "runtime.authz.policy.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": PermissionRunRead,
			"runId":      runID,
			"tenantId":   run.TenantID,
			"projectId":  run.ProjectID,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return
	}
	emitAuditEvent(r.Context(), "runtime.authz.policy.allow", map[string]interface{}{
		"path":       r.URL.Path,
		"method":     r.Method,
		"permission": PermissionRunRead,
		"runId":      runID,
		"tenantId":   run.TenantID,
		"projectId":  run.ProjectID,
	})

	emitAuditEvent(r.Context(), "runtime.run.read", map[string]interface{}{
		"path":      r.URL.Path,
		"method":    r.Method,
		"runId":     runID,
		"tenantId":  run.TenantID,
		"projectId": run.ProjectID,
		"status":    run.Status,
	})
	writeJSON(w, http.StatusOK, run)
}

func (s *APIServer) handleAuditEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", false, nil)
		return
	}
	ctx, ok := s.authorizeRequest(w, r, PermissionRunRead)
	if !ok {
		return
	}
	r = r.WithContext(ctx)

	limit := 100
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeAPIError(w, http.StatusBadRequest, "INVALID_LIMIT", "limit must be an integer", false, map[string]interface{}{"limit": raw})
			return
		}
		limit = parsed
	}

	query := RuntimeAuditQuery{
		Limit:      limit,
		TenantID:   strings.TrimSpace(r.URL.Query().Get("tenantId")),
		ProjectID:  strings.TrimSpace(r.URL.Query().Get("projectId")),
		ProviderID: strings.TrimSpace(r.URL.Query().Get("providerId")),
		Decision:   strings.TrimSpace(r.URL.Query().Get("decision")),
		Event:      strings.TrimSpace(r.URL.Query().Get("event")),
	}
	items := ListRuntimeAuditEvents(query)
	identity, _ := RuntimeIdentityFromContext(r.Context())
	filtered, deniedByAuthz := filterAuditEventsByAuthorization(items, identity, s.auth, PermissionRunRead)

	emitAuditEvent(r.Context(), "runtime.audit.list", map[string]interface{}{
		"path":            r.URL.Path,
		"method":          r.Method,
		"requestedLimit":  limit,
		"returnedCount":   len(filtered),
		"unfilteredCount": len(items),
		"filteredDenied":  deniedByAuthz,
		"tenantFilter":    query.TenantID,
		"projectFilter":   query.ProjectID,
		"providerFilter":  query.ProviderID,
		"decisionFilter":  strings.ToUpper(query.Decision),
		"eventFilter":     query.Event,
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"source":          "runtime-memory",
		"count":           len(filtered),
		"unfilteredCount": len(items),
		"filteredDenied":  deniedByAuthz,
		"items":           filtered,
	})
}

func (s *APIServer) authorizeRequest(w http.ResponseWriter, r *http.Request, permission string) (context.Context, bool) {
	if s.auth == nil || !s.auth.Enabled() {
		return r.Context(), true
	}

	identity, err := s.auth.AuthenticateRequest(r)
	if err != nil {
		emitAuditEvent(r.Context(), "runtime.authn.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": permission,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return nil, false
	}
	if err := s.auth.Authorize(identity, permission); err != nil {
		ctxWithIdentity := withRuntimeIdentity(r.Context(), identity)
		emitAuditEvent(ctxWithIdentity, "runtime.authz.deny", map[string]interface{}{
			"path":       r.URL.Path,
			"method":     r.Method,
			"permission": permission,
			"error":      err.Error(),
		})
		s.writeAuthError(w, err)
		return nil, false
	}

	ctxWithIdentity := withRuntimeIdentity(r.Context(), identity)
	emitAuditEvent(ctxWithIdentity, "runtime.authz.allow", map[string]interface{}{
		"path":       r.URL.Path,
		"method":     r.Method,
		"permission": permission,
	})
	return ctxWithIdentity, true
}

func (s *APIServer) writeAuthError(w http.ResponseWriter, err error) {
	details := map[string]interface{}{"error": err.Error()}
	switch {
	case errors.Is(err, ErrForbidden):
		writeAPIError(w, http.StatusForbidden, "FORBIDDEN", "request is not authorized for this operation", false, details)
	case errors.Is(err, ErrAuthRequired), errors.Is(err, ErrInvalidToken):
		writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "authentication required", false, details)
	default:
		writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "authentication failed", false, details)
	}
}

func (s *APIServer) authorizeScoped(identity *RuntimeIdentity, permission, tenantID, projectID string) error {
	if s.auth == nil || !s.auth.Enabled() {
		return nil
	}
	return s.auth.AuthorizeScoped(identity, permission, tenantID, projectID)
}

func injectActorIdentity(meta *ObjectMeta, ctx context.Context) {
	identity, ok := RuntimeIdentityFromContext(ctx)
	if !ok || identity == nil {
		return
	}
	if meta.Actor == nil {
		meta.Actor = JSONObject{}
	}
	if _, exists := meta.Actor["subject"]; !exists {
		meta.Actor["subject"] = identity.Subject
	}
	if identity.ClientID != "" {
		if _, exists := meta.Actor["clientId"]; !exists {
			meta.Actor["clientId"] = identity.ClientID
		}
	}
	if len(identity.Roles) > 0 {
		if _, exists := meta.Actor["roles"]; !exists {
			roles := append([]string(nil), identity.Roles...)
			meta.Actor["roles"] = roles
		}
	}
	if _, exists := meta.Actor["authn"]; !exists {
		meta.Actor["authn"] = "oidc-jwt"
	}
	if len(identity.TenantIDs) > 0 {
		if _, exists := meta.Actor["tenantScopes"]; !exists {
			meta.Actor["tenantScopes"] = append([]string(nil), identity.TenantIDs...)
		}
	}
	if len(identity.ProjectIDs) > 0 {
		if _, exists := meta.Actor["projectScopes"]; !exists {
			meta.Actor["projectScopes"] = append([]string(nil), identity.ProjectIDs...)
		}
	}
}

func enforceRequestMetaScope(meta *ObjectMeta, identity *RuntimeIdentity) error {
	if identity == nil || meta == nil {
		return nil
	}

	meta.TenantID = strings.TrimSpace(meta.TenantID)
	meta.ProjectID = strings.TrimSpace(meta.ProjectID)

	if meta.TenantID == "" && len(identity.TenantIDs) == 1 {
		meta.TenantID = identity.TenantIDs[0]
	}
	if meta.ProjectID == "" && len(identity.ProjectIDs) == 1 {
		meta.ProjectID = identity.ProjectIDs[0]
	}

	return enforceRunRecordScope(meta.TenantID, meta.ProjectID, identity)
}

func enforceRunRecordScope(tenantID, projectID string, identity *RuntimeIdentity) error {
	if identity == nil {
		return nil
	}
	tenantID = strings.TrimSpace(tenantID)
	projectID = strings.TrimSpace(projectID)

	if len(identity.TenantIDs) > 0 {
		if tenantID == "" {
			return fmt.Errorf("%w: tenant scope is required", ErrForbidden)
		}
		if !identity.AllowsTenant(tenantID) {
			return fmt.Errorf("%w: tenantId %q is outside token scope", ErrForbidden, tenantID)
		}
	}
	if len(identity.ProjectIDs) > 0 {
		if projectID == "" {
			return fmt.Errorf("%w: project scope is required", ErrForbidden)
		}
		if !identity.AllowsProject(projectID) {
			return fmt.Errorf("%w: projectId %q is outside token scope", ErrForbidden, projectID)
		}
	}
	return nil
}

func filterRunSummariesByAuthorization(items []RunSummary, identity *RuntimeIdentity, auth *AuthEnforcer, permission string) ([]RunSummary, int) {
	out := make([]RunSummary, 0, len(items))
	denied := 0
	for _, item := range items {
		if err := enforceRunRecordScope(item.TenantID, item.ProjectID, identity); err != nil {
			denied++
			continue
		}
		if auth != nil && auth.Enabled() {
			if err := auth.AuthorizeScoped(identity, permission, item.TenantID, item.ProjectID); err != nil {
				denied++
				continue
			}
		}
		out = append(out, item)
	}
	return out, denied
}

func filterAuditEventsByAuthorization(items []map[string]interface{}, identity *RuntimeIdentity, auth *AuthEnforcer, permission string) ([]map[string]interface{}, int) {
	out := make([]map[string]interface{}, 0, len(items))
	denied := 0
	for _, item := range items {
		tenantID := runtimeAuditRecordString(item, "tenantId")
		projectID := runtimeAuditRecordString(item, "projectId")

		if err := enforceRunRecordScope(tenantID, projectID, identity); err != nil {
			denied++
			continue
		}
		if auth != nil && auth.Enabled() {
			if err := auth.AuthorizeScoped(identity, permission, tenantID, projectID); err != nil {
				denied++
				continue
			}
		}
		out = append(out, cloneInterfaceMap(item))
	}
	return out, denied
}

func writeAPIError(w http.ResponseWriter, code int, errorCode, msg string, retryable bool, details map[string]interface{}) {
	writeJSON(w, code, APIError{
		ErrorCode: errorCode,
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

type ServerConfig struct {
	ListenAddr string
}

func StartHTTPServer(ctx context.Context, cfg ServerConfig, handler http.Handler) error {
	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("listen: %w", err)
		}
		close(errCh)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		return ctx.Err()
	case err := <-errCh:
		return err
	}
}
