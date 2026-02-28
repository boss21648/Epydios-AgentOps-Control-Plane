package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Orchestrator struct {
	Namespace           string
	Store               RunStore
	ProviderRegistry    *ProviderRegistry
	ProfileMinPriority  int64
	PolicyMinPriority   int64
	EvidenceMinPriority int64
	RequirePolicyGrant  bool
}

func (o *Orchestrator) ExecuteRun(ctx context.Context, req RunCreateRequest) (*RunRecord, error) {
	if err := validateRunCreateRequest(req); err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	normalizedReq := req
	if normalizedReq.Meta.Timestamp == nil {
		normalizedReq.Meta.Timestamp = &now
	}
	if strings.TrimSpace(normalizedReq.Meta.RequestID) == "" {
		normalizedReq.Meta.RequestID = "req-" + strings.ReplaceAll(uuid.NewString(), "-", "")
	}
	if strings.TrimSpace(normalizedReq.Mode) == "" {
		normalizedReq.Mode = "enforce"
	}
	if strings.TrimSpace(normalizedReq.RetentionClass) == "" {
		normalizedReq.RetentionClass = "standard"
	}

	runID := "run-" + strings.ReplaceAll(uuid.NewString(), "-", "")
	requestPayload, err := json.Marshal(normalizedReq)
	if err != nil {
		return nil, fmt.Errorf("marshal run request payload: %w", err)
	}

	run := &RunRecord{
		RunID:          runID,
		RequestID:      normalizedReq.Meta.RequestID,
		TenantID:       normalizedReq.Meta.TenantID,
		ProjectID:      normalizedReq.Meta.ProjectID,
		Environment:    normalizedReq.Meta.Environment,
		Status:         RunStatusPending,
		RequestPayload: requestPayload,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	if err := o.Store.UpsertRun(ctx, run); err != nil {
		return nil, fmt.Errorf("persist pending run: %w", err)
	}
	emitAuditEvent(ctx, "runtime.run.started", map[string]interface{}{
		"runId":       run.RunID,
		"requestId":   run.RequestID,
		"tenantId":    run.TenantID,
		"projectId":   run.ProjectID,
		"environment": run.Environment,
		"mode":        normalizedReq.Mode,
		"dryRun":      normalizedReq.DryRun,
	})

	failRun := func(cause error) (*RunRecord, error) {
		run.Status = RunStatusFailed
		run.ErrorMessage = cause.Error()
		run.UpdatedAt = time.Now().UTC()
		_ = o.Store.UpsertRun(ctx, run)
		emitAuditEvent(ctx, "runtime.run.failed", map[string]interface{}{
			"runId":     run.RunID,
			"requestId": run.RequestID,
			"tenantId":  run.TenantID,
			"projectId": run.ProjectID,
			"status":    run.Status,
			"policy":    run.PolicyDecision,
			"error":     cause.Error(),
		})
		return run, cause
	}

	profileProvider, err := o.ProviderRegistry.SelectProvider(ctx, o.Namespace, "ProfileResolver", "profile.resolve", o.ProfileMinPriority)
	if err != nil {
		return failRun(fmt.Errorf("select profile provider: %w", err))
	}
	run.SelectedProfileProvider = profileProvider.Name
	emitAuditEvent(ctx, "runtime.provider.selected", map[string]interface{}{
		"runId":        run.RunID,
		"providerType": "ProfileResolver",
		"providerName": profileProvider.Name,
		"providerId":   profileProvider.ProviderID,
		"capability":   "profile.resolve",
		"priority":     profileProvider.Priority,
		"authMode":     profileProvider.AuthMode,
	})

	profileReq := map[string]interface{}{
		"meta": map[string]interface{}{
			"requestId":   normalizedReq.Meta.RequestID,
			"timestamp":   normalizedReq.Meta.Timestamp.Format(time.RFC3339),
			"tenantId":    normalizedReq.Meta.TenantID,
			"projectId":   normalizedReq.Meta.ProjectID,
			"environment": normalizedReq.Meta.Environment,
		},
		"workload": normalizedReq.Workload,
		"subject":  normalizedReq.Subject,
		"task":     normalizedReq.Task,
		"defaults": normalizedReq.Defaults,
		"context":  normalizedReq.Context,
	}

	var profileResp map[string]interface{}
	if err := o.ProviderRegistry.PostJSON(ctx, profileProvider, "/v1alpha1/profile-resolver/resolve", profileReq, &profileResp); err != nil {
		return failRun(fmt.Errorf("profile provider call: %w", err))
	}
	if run.ProfileResponse, err = json.Marshal(profileResp); err != nil {
		return failRun(fmt.Errorf("marshal profile response: %w", err))
	}
	run.Status = RunStatusProfileResolved
	run.UpdatedAt = time.Now().UTC()
	if err := o.Store.UpsertRun(ctx, run); err != nil {
		return failRun(fmt.Errorf("persist profile stage: %w", err))
	}

	policyProvider, err := o.ProviderRegistry.SelectProvider(ctx, o.Namespace, "PolicyProvider", "policy.evaluate", o.PolicyMinPriority)
	if err != nil {
		return failRun(fmt.Errorf("select policy provider: %w", err))
	}
	run.SelectedPolicyProvider = policyProvider.Name
	emitAuditEvent(ctx, "runtime.provider.selected", map[string]interface{}{
		"runId":        run.RunID,
		"providerType": "PolicyProvider",
		"providerName": policyProvider.Name,
		"providerId":   policyProvider.ProviderID,
		"capability":   "policy.evaluate",
		"priority":     policyProvider.Priority,
		"authMode":     policyProvider.AuthMode,
	})

	policyReq := map[string]interface{}{
		"meta": map[string]interface{}{
			"requestId":   normalizedReq.Meta.RequestID,
			"timestamp":   normalizedReq.Meta.Timestamp.Format(time.RFC3339),
			"tenantId":    normalizedReq.Meta.TenantID,
			"projectId":   normalizedReq.Meta.ProjectID,
			"environment": normalizedReq.Meta.Environment,
			"actor":       normalizedReq.Meta.Actor,
		},
		"profile":  profileResp,
		"subject":  normalizedReq.Subject,
		"action":   normalizedReq.Action,
		"resource": normalizedReq.Resource,
		"context":  normalizedReq.Context,
		"mode":     normalizedReq.Mode,
		"dryRun":   normalizedReq.DryRun,
	}

	var policyResp map[string]interface{}
	if err := o.ProviderRegistry.PostJSON(ctx, policyProvider, "/v1alpha1/policy-provider/evaluate", policyReq, &policyResp); err != nil {
		return failRun(fmt.Errorf("policy provider call: %w", err))
	}
	decision, _ := policyResp["decision"].(string)
	if strings.TrimSpace(decision) == "" {
		return failRun(fmt.Errorf("policy provider response missing decision"))
	}
	decisionUpper := strings.ToUpper(strings.TrimSpace(decision))
	run.PolicyDecision = decisionUpper

	grantToken, grantTokenSource := extractPolicyGrantToken(policyResp)
	if grantToken != "" {
		run.PolicyGrantTokenPresent = true
		run.PolicyGrantTokenSHA256 = "sha256:" + sha256Hex(grantToken)
	}
	if o.RequirePolicyGrant && decisionRequiresGrant(decisionUpper) && !run.PolicyGrantTokenPresent {
		emitAuditEvent(ctx, "runtime.policy.grant.missing", map[string]interface{}{
			"runId":          run.RunID,
			"requestId":      run.RequestID,
			"decision":       decisionUpper,
			"policyProvider": run.SelectedPolicyProvider,
			"required":       true,
		})
		return failRun(fmt.Errorf("policy provider response missing grant token for decision %s", decisionUpper))
	}
	sanitizedPolicyResp := sanitizePolicyResponse(policyResp, run.PolicyGrantTokenPresent, run.PolicyGrantTokenSHA256, grantTokenSource)
	if run.PolicyResponse, err = json.Marshal(sanitizedPolicyResp); err != nil {
		return failRun(fmt.Errorf("marshal policy response: %w", err))
	}
	emitAuditEvent(ctx, "runtime.policy.decision", map[string]interface{}{
		"runId":          run.RunID,
		"requestId":      run.RequestID,
		"decision":       decisionUpper,
		"policyProvider": run.SelectedPolicyProvider,
		"grantRequired":  o.RequirePolicyGrant && decisionRequiresGrant(decisionUpper),
		"grantPresent":   run.PolicyGrantTokenPresent,
		"grantSource":    grantTokenSource,
		"grantSha256":    run.PolicyGrantTokenSHA256,
	})
	if run.PolicyGrantTokenPresent {
		emitAuditEvent(ctx, "runtime.policy.grant.accepted", map[string]interface{}{
			"runId":          run.RunID,
			"requestId":      run.RequestID,
			"decision":       decisionUpper,
			"policyProvider": run.SelectedPolicyProvider,
			"grantSource":    grantTokenSource,
			"grantSha256":    run.PolicyGrantTokenSHA256,
		})
	}
	run.Status = RunStatusPolicyEvaluated
	run.UpdatedAt = time.Now().UTC()
	if err := o.Store.UpsertRun(ctx, run); err != nil {
		return failRun(fmt.Errorf("persist policy stage: %w", err))
	}

	evidenceProvider, err := o.ProviderRegistry.SelectProvider(ctx, o.Namespace, "EvidenceProvider", "evidence.record", o.EvidenceMinPriority)
	if err != nil {
		return failRun(fmt.Errorf("select evidence provider: %w", err))
	}
	run.SelectedEvidenceProvider = evidenceProvider.Name
	emitAuditEvent(ctx, "runtime.provider.selected", map[string]interface{}{
		"runId":        run.RunID,
		"providerType": "EvidenceProvider",
		"providerName": evidenceProvider.Name,
		"providerId":   evidenceProvider.ProviderID,
		"capability":   "evidence.record",
		"priority":     evidenceProvider.Priority,
		"authMode":     evidenceProvider.AuthMode,
	})

	eventType := "controlplane.policy.authorized"
	stage := "authorize"
	if decisionUpper == "DENY" {
		eventType = "controlplane.policy.denied"
		stage = "deny"
	}

	recordReq := map[string]interface{}{
		"meta": map[string]interface{}{
			"requestId":   normalizedReq.Meta.RequestID,
			"timestamp":   normalizedReq.Meta.Timestamp.Format(time.RFC3339),
			"tenantId":    normalizedReq.Meta.TenantID,
			"projectId":   normalizedReq.Meta.ProjectID,
			"environment": normalizedReq.Meta.Environment,
			"actor":       normalizedReq.Meta.Actor,
		},
		"eventType": eventType,
		"eventId":   fmt.Sprintf("%s-%s", run.RunID, stage),
		"runId":     run.RunID,
		"stage":     stage,
		"payload": map[string]interface{}{
			"profile": profileResp,
			"policy":  sanitizedPolicyResp,
			"context": normalizedReq.Context,
		},
		"retentionClass": normalizedReq.RetentionClass,
	}

	var recordResp map[string]interface{}
	if err := o.ProviderRegistry.PostJSON(ctx, evidenceProvider, "/v1alpha1/evidence-provider/record", recordReq, &recordResp); err != nil {
		return failRun(fmt.Errorf("evidence record call: %w", err))
	}
	evidenceID, _ := recordResp["evidenceId"].(string)
	if strings.TrimSpace(evidenceID) == "" {
		return failRun(fmt.Errorf("evidence record response missing evidenceId"))
	}
	if run.EvidenceRecordResponse, err = json.Marshal(recordResp); err != nil {
		return failRun(fmt.Errorf("marshal evidence record response: %w", err))
	}
	run.Status = RunStatusEvidenceRecorded
	run.UpdatedAt = time.Now().UTC()
	if err := o.Store.UpsertRun(ctx, run); err != nil {
		return failRun(fmt.Errorf("persist evidence record stage: %w", err))
	}

	finalizeReq := map[string]interface{}{
		"meta": map[string]interface{}{
			"requestId": fmt.Sprintf("%s-finalize", normalizedReq.Meta.RequestID),
			"timestamp": time.Now().UTC().Format(time.RFC3339),
			"tenantId":  normalizedReq.Meta.TenantID,
			"projectId": normalizedReq.Meta.ProjectID,
		},
		"bundleId":       "bundle-" + run.RunID,
		"runId":          run.RunID,
		"evidenceIds":    []string{evidenceID},
		"retentionClass": normalizedReq.RetentionClass,
		"annotations": map[string]interface{}{
			"selectedProfileProvider":  run.SelectedProfileProvider,
			"selectedPolicyProvider":   run.SelectedPolicyProvider,
			"selectedEvidenceProvider": run.SelectedEvidenceProvider,
			"decision":                 decisionUpper,
		},
	}

	var finalizeResp map[string]interface{}
	if err := o.ProviderRegistry.PostJSON(ctx, evidenceProvider, "/v1alpha1/evidence-provider/finalize-bundle", finalizeReq, &finalizeResp); err != nil {
		return failRun(fmt.Errorf("evidence finalize call: %w", err))
	}
	if run.EvidenceBundleResponse, err = json.Marshal(finalizeResp); err != nil {
		return failRun(fmt.Errorf("marshal evidence finalize response: %w", err))
	}
	run.Status = RunStatusCompleted
	run.UpdatedAt = time.Now().UTC()
	if err := o.Store.UpsertRun(ctx, run); err != nil {
		return failRun(fmt.Errorf("persist completion stage: %w", err))
	}
	emitAuditEvent(ctx, "runtime.run.completed", map[string]interface{}{
		"runId":            run.RunID,
		"requestId":        run.RequestID,
		"tenantId":         run.TenantID,
		"projectId":        run.ProjectID,
		"status":           run.Status,
		"policy":           decisionUpper,
		"profileProvider":  run.SelectedProfileProvider,
		"policyProvider":   run.SelectedPolicyProvider,
		"evidenceProvider": run.SelectedEvidenceProvider,
		"grantPresent":     run.PolicyGrantTokenPresent,
		"grantSha256":      run.PolicyGrantTokenSHA256,
	})

	return run, nil
}

func validateRunCreateRequest(req RunCreateRequest) error {
	if strings.TrimSpace(req.Meta.RequestID) == "" {
		// requestId is auto-generated if absent; this is not an error.
	}
	if len(req.Subject) == 0 {
		return fmt.Errorf("subject is required")
	}
	if len(req.Action) == 0 {
		return fmt.Errorf("action is required")
	}
	return nil
}

func decisionRequiresGrant(decision string) bool {
	return strings.ToUpper(strings.TrimSpace(decision)) != "DENY"
}

func extractPolicyGrantToken(policyResp map[string]interface{}) (string, string) {
	if token := strings.TrimSpace(policyValueToString(policyResp["grantToken"])); token != "" {
		return token, "grantToken"
	}
	if token := strings.TrimSpace(policyValueToString(policyResp["grant_token"])); token != "" {
		return token, "grant_token"
	}
	if token := strings.TrimSpace(policyValueToString(policyResp["capabilityGrant"])); token != "" {
		return token, "capabilityGrant"
	}
	if token := strings.TrimSpace(policyValueToString(policyResp["capability_grant"])); token != "" {
		return token, "capability_grant"
	}
	output, _ := policyResp["output"].(map[string]interface{})
	if len(output) == 0 {
		return "", ""
	}
	for _, candidate := range []string{"grantToken", "grant_token", "aimxsGrantToken", "aimxs_grant_token"} {
		if token := strings.TrimSpace(policyValueToString(output[candidate])); token != "" {
			return token, "output." + candidate
		}
	}
	return "", ""
}

func sanitizePolicyResponse(policyResp map[string]interface{}, grantPresent bool, grantSHA256 string, grantSource string) map[string]interface{} {
	encoded, err := json.Marshal(policyResp)
	if err != nil {
		return map[string]interface{}{
			"decision":          strings.TrimSpace(policyValueToString(policyResp["decision"])),
			"grantTokenPresent": grantPresent,
			"grantTokenSha256":  grantSHA256,
			"grantTokenSource":  grantSource,
		}
	}
	var cloned map[string]interface{}
	if err := json.Unmarshal(encoded, &cloned); err != nil {
		return map[string]interface{}{
			"decision":          strings.TrimSpace(policyValueToString(policyResp["decision"])),
			"grantTokenPresent": grantPresent,
			"grantTokenSha256":  grantSHA256,
			"grantTokenSource":  grantSource,
		}
	}
	removeTokenKeys(cloned, "grantToken", "grant_token", "capabilityGrant", "capability_grant")
	if output, ok := cloned["output"].(map[string]interface{}); ok {
		removeTokenKeys(output, "grantToken", "grant_token", "aimxsGrantToken", "aimxs_grant_token")
	}
	cloned["grantTokenPresent"] = grantPresent
	if grantSHA256 != "" {
		cloned["grantTokenSha256"] = grantSHA256
	}
	if grantSource != "" {
		cloned["grantTokenSource"] = grantSource
	}
	return cloned
}

func removeTokenKeys(m map[string]interface{}, keys ...string) {
	for _, key := range keys {
		delete(m, key)
	}
}

func policyValueToString(v interface{}) string {
	switch typed := v.(type) {
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	default:
		return ""
	}
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
