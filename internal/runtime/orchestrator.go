package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Orchestrator struct {
	Namespace             string
	Store                 RunStore
	ProviderRegistry      *ProviderRegistry
	ProfileMinPriority    int64
	PolicyMinPriority     int64
	EvidenceMinPriority   int64
	RequirePolicyGrant    bool
	AIMXSEntitlement      AIMXSEntitlementConfig
	PolicyLifecycle       PolicyLifecycleConfig
	RetentionDefaultClass string
	RetentionClassTTLs    map[string]time.Duration
}

type AIMXSEntitlementConfig struct {
	Enabled               bool
	ProviderNamePrefixes  []string
	AllowedSKUs           map[string]struct{}
	SKUFeatures           map[string]map[string]struct{}
	RequiredFeatures      map[string]struct{}
	RequireEntitlementKey bool
}

type PolicyLifecycleConfig struct {
	Enabled          bool
	Mode             string
	AllowedPolicyIDs map[string]struct{}
	MinVersion       string
	RolloutPercent   int
}

type entitlementRequestDetails struct {
	SKU        string
	Token      string
	Features   map[string]struct{}
	RawFeature []string
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
		normalizedReq.RetentionClass = firstNonEmpty(strings.TrimSpace(o.RetentionDefaultClass), "standard")
	}
	retentionTTL, err := o.retentionTTLForClass(normalizedReq.RetentionClass)
	if err != nil {
		return nil, err
	}
	var expiresAt *time.Time
	if retentionTTL > 0 {
		expires := now.Add(retentionTTL).UTC()
		expiresAt = &expires
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
		RetentionClass: normalizedReq.RetentionClass,
		ExpiresAt:      expiresAt,
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
	policyDecisionSource := "provider"
	if denyResp, ok := o.evaluateAIMXSEntitlement(ctx, run, policyProvider, normalizedReq); ok {
		policyResp = denyResp
		policyDecisionSource = "runtime-entitlement"
	} else {
		if err := o.ProviderRegistry.PostJSON(ctx, policyProvider, "/v1alpha1/policy-provider/evaluate", policyReq, &policyResp); err != nil {
			return failRun(fmt.Errorf("policy provider call: %w", err))
		}
	}
	decision, _ := policyResp["decision"].(string)
	if strings.TrimSpace(decision) == "" {
		return failRun(fmt.Errorf("policy provider response missing decision"))
	}
	decisionUpper := strings.ToUpper(strings.TrimSpace(decision))
	run.PolicyDecision = decisionUpper
	policyBundle := extractPolicyBundleRef(policyResp)
	run.PolicyBundleID = policyBundle.PolicyID
	run.PolicyBundleVersion = policyBundle.PolicyVersion

	if policyDecisionSource == "provider" {
		if err := o.evaluatePolicyLifecycle(ctx, run, policyBundle); err != nil {
			return failRun(err)
		}
	}

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
		"decisionSource": policyDecisionSource,
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

func (o *Orchestrator) retentionTTLForClass(retentionClass string) (time.Duration, error) {
	retentionClass = strings.TrimSpace(retentionClass)
	if retentionClass == "" {
		return 0, fmt.Errorf("retentionClass is required")
	}
	if len(o.RetentionClassTTLs) == 0 {
		return 0, nil
	}
	ttl, ok := o.RetentionClassTTLs[retentionClass]
	if !ok {
		return 0, fmt.Errorf("unsupported retentionClass %q", retentionClass)
	}
	if ttl < 0 {
		return 0, fmt.Errorf("invalid retention TTL for class %q", retentionClass)
	}
	return ttl, nil
}

func (o *Orchestrator) evaluatePolicyLifecycle(ctx context.Context, run *RunRecord, bundle PolicyBundleRef) error {
	if !o.PolicyLifecycle.Enabled {
		return nil
	}
	mode := strings.ToLower(strings.TrimSpace(o.PolicyLifecycle.Mode))
	if mode == "" {
		mode = "observe"
	}
	if mode != "observe" && mode != "enforce" {
		mode = "observe"
	}

	violations := make([]string, 0, 4)
	policyID := strings.TrimSpace(bundle.PolicyID)
	policyVersion := strings.TrimSpace(bundle.PolicyVersion)

	if policyID == "" {
		violations = append(violations, "policyBundle.policyId is missing")
	}
	if policyVersion == "" {
		violations = append(violations, "policyBundle.policyVersion is missing")
	}
	if len(o.PolicyLifecycle.AllowedPolicyIDs) > 0 && policyID != "" {
		if _, ok := o.PolicyLifecycle.AllowedPolicyIDs[policyID]; !ok {
			violations = append(violations, fmt.Sprintf("policyId %q not in allowed policy set", policyID))
		}
	}
	minVersion := strings.TrimSpace(o.PolicyLifecycle.MinVersion)
	if minVersion != "" && policyVersion != "" && comparePolicyVersions(policyVersion, minVersion) < 0 {
		violations = append(violations, fmt.Sprintf("policyVersion %q is below minimum %q", policyVersion, minVersion))
	}

	rolloutPercent := o.PolicyLifecycle.RolloutPercent
	if rolloutPercent <= 0 || rolloutPercent > 100 {
		rolloutPercent = 100
	}
	rolloutBucket := stableRolloutBucket(run.RequestID, policyID, policyVersion)
	if rolloutPercent < 100 && rolloutBucket >= rolloutPercent {
		violations = append(violations, fmt.Sprintf("policyVersion %q held back by rolloutPercent=%d (bucket=%d)", policyVersion, rolloutPercent, rolloutBucket))
	}

	emitAuditEvent(ctx, "runtime.policy.lifecycle.evaluate", map[string]interface{}{
		"runId":          run.RunID,
		"requestId":      run.RequestID,
		"mode":           mode,
		"policyId":       policyID,
		"policyVersion":  policyVersion,
		"minVersion":     minVersion,
		"rolloutPercent": rolloutPercent,
		"rolloutBucket":  rolloutBucket,
		"violations":     append([]string(nil), violations...),
	})

	if len(violations) == 0 {
		emitAuditEvent(ctx, "runtime.policy.lifecycle.allow", map[string]interface{}{
			"runId":         run.RunID,
			"requestId":     run.RequestID,
			"policyId":      policyID,
			"policyVersion": policyVersion,
		})
		return nil
	}

	event := "runtime.policy.lifecycle.observe_violation"
	if mode == "enforce" {
		event = "runtime.policy.lifecycle.deny"
	}
	emitAuditEvent(ctx, event, map[string]interface{}{
		"runId":         run.RunID,
		"requestId":     run.RequestID,
		"policyId":      policyID,
		"policyVersion": policyVersion,
		"violations":    append([]string(nil), violations...),
	})
	if mode == "enforce" {
		return fmt.Errorf("policy lifecycle validation failed: %s", strings.Join(violations, "; "))
	}
	return nil
}

func (o *Orchestrator) evaluateAIMXSEntitlement(ctx context.Context, run *RunRecord, provider *ProviderTarget, req RunCreateRequest) (map[string]interface{}, bool) {
	if !o.shouldApplyAIMXSEntitlement(provider) {
		return nil, false
	}

	details := extractEntitlementRequestDetails(req)
	requiredFeatures := o.entitlementRequiredFeaturesForSKU(details.SKU)
	tokenPresent := strings.TrimSpace(details.Token) != ""

	violationCodes := make([]string, 0, 4)
	violationMessages := make([]string, 0, 4)

	if o.AIMXSEntitlement.RequireEntitlementKey && !tokenPresent {
		violationCodes = append(violationCodes, "AIMXS_ENTITLEMENT_TOKEN_REQUIRED")
		violationMessages = append(violationMessages, "missing required AIMXS entitlement token")
	}
	if len(o.AIMXSEntitlement.AllowedSKUs) > 0 {
		if details.SKU == "" {
			violationCodes = append(violationCodes, "AIMXS_ENTITLEMENT_SKU_REQUIRED")
			violationMessages = append(violationMessages, "missing required AIMXS SKU")
		} else if _, ok := o.AIMXSEntitlement.AllowedSKUs[details.SKU]; !ok {
			violationCodes = append(violationCodes, "AIMXS_ENTITLEMENT_SKU_NOT_ALLOWED")
			violationMessages = append(violationMessages, fmt.Sprintf("AIMXS SKU %q is not allowed", details.SKU))
		}
	}

	missingFeatures := make([]string, 0, len(requiredFeatures))
	for _, required := range requiredFeatures {
		if _, ok := details.Features[required]; !ok {
			missingFeatures = append(missingFeatures, required)
		}
	}
	if len(missingFeatures) > 0 {
		violationCodes = append(violationCodes, "AIMXS_ENTITLEMENT_FEATURE_MISSING")
		violationMessages = append(violationMessages, fmt.Sprintf("missing required AIMXS features: %s", strings.Join(missingFeatures, ",")))
	}

	emitAuditEvent(ctx, "runtime.aimxs.entitlement.evaluate", map[string]interface{}{
		"runId":            run.RunID,
		"requestId":        run.RequestID,
		"providerName":     provider.Name,
		"providerId":       provider.ProviderID,
		"sku":              details.SKU,
		"tokenPresent":     tokenPresent,
		"features":         sortedSetKeys(details.Features),
		"requiredFeatures": requiredFeatures,
		"violations":       append([]string(nil), violationCodes...),
		"allowed":          len(violationCodes) == 0,
	})

	if len(violationCodes) == 0 {
		emitAuditEvent(ctx, "runtime.aimxs.entitlement.allow", map[string]interface{}{
			"runId":            run.RunID,
			"requestId":        run.RequestID,
			"providerName":     provider.Name,
			"providerId":       provider.ProviderID,
			"sku":              details.SKU,
			"tokenPresent":     tokenPresent,
			"features":         sortedSetKeys(details.Features),
			"requiredFeatures": requiredFeatures,
		})
		return nil, false
	}

	emitAuditEvent(ctx, "runtime.aimxs.entitlement.deny", map[string]interface{}{
		"runId":            run.RunID,
		"requestId":        run.RequestID,
		"providerName":     provider.Name,
		"providerId":       provider.ProviderID,
		"sku":              details.SKU,
		"tokenPresent":     tokenPresent,
		"features":         sortedSetKeys(details.Features),
		"requiredFeatures": requiredFeatures,
		"violations":       append([]string(nil), violationCodes...),
	})

	return buildEntitlementDenyPolicyResponse(provider, details, requiredFeatures, missingFeatures, violationCodes, violationMessages), true
}

func (o *Orchestrator) shouldApplyAIMXSEntitlement(provider *ProviderTarget) bool {
	if !o.AIMXSEntitlement.Enabled || provider == nil {
		return false
	}
	if len(o.AIMXSEntitlement.ProviderNamePrefixes) == 0 {
		return false
	}
	candidates := []string{provider.Name, provider.ProviderID}
	for _, candidate := range candidates {
		candidateNorm := strings.ToLower(strings.TrimSpace(candidate))
		if candidateNorm == "" {
			continue
		}
		for _, prefix := range o.AIMXSEntitlement.ProviderNamePrefixes {
			prefixNorm := strings.ToLower(strings.TrimSpace(prefix))
			if prefixNorm == "" {
				continue
			}
			if strings.HasPrefix(candidateNorm, prefixNorm) {
				return true
			}
		}
	}
	return false
}

func (o *Orchestrator) entitlementRequiredFeaturesForSKU(sku string) []string {
	required := make(map[string]struct{}, len(o.AIMXSEntitlement.RequiredFeatures))
	for feature := range o.AIMXSEntitlement.RequiredFeatures {
		if feature != "" {
			required[feature] = struct{}{}
		}
	}
	if sku != "" {
		if skuFeatures, ok := o.AIMXSEntitlement.SKUFeatures[sku]; ok {
			for feature := range skuFeatures {
				if feature != "" {
					required[feature] = struct{}{}
				}
			}
		}
	}
	return sortedSetKeys(required)
}

func extractEntitlementRequestDetails(req RunCreateRequest) entitlementRequestDetails {
	details := entitlementRequestDetails{
		Features: make(map[string]struct{}),
	}
	if req.Annotations == nil {
		return details
	}

	annotations := map[string]interface{}(req.Annotations)
	details.SKU = normalizeEntitlementKey(firstNonEmpty(
		nestedStringValue(annotations, "aimxsEntitlement", "sku"),
		nestedStringValue(annotations, "aimxs", "entitlement", "sku"),
		stringValue(annotations["aimxs.sku"]),
		stringValue(annotations["aimxsSku"]),
		stringValue(annotations["aimxsSKU"]),
		stringValue(annotations["entitlementSku"]),
	))
	details.Token = strings.TrimSpace(firstNonEmpty(
		nestedStringValue(annotations, "aimxsEntitlement", "token"),
		nestedStringValue(annotations, "aimxs", "entitlement", "token"),
		stringValue(annotations["aimxs.token"]),
		stringValue(annotations["aimxsToken"]),
		stringValue(annotations["aimxsEntitlementToken"]),
		stringValue(annotations["entitlementToken"]),
	))

	featureValues := make([]string, 0, 8)
	featureValues = append(featureValues, entitlementFeaturesFromValue(nestedValue(annotations, "aimxsEntitlement", "features"))...)
	featureValues = append(featureValues, entitlementFeaturesFromValue(nestedValue(annotations, "aimxs", "entitlement", "features"))...)
	featureValues = append(featureValues, entitlementFeaturesFromValue(annotations["aimxs.features"])...)
	featureValues = append(featureValues, entitlementFeaturesFromValue(annotations["aimxsFeatures"])...)
	featureValues = append(featureValues, entitlementFeaturesFromValue(annotations["entitlementFeatures"])...)

	seen := make(map[string]struct{}, len(featureValues))
	for _, feature := range featureValues {
		norm := normalizeEntitlementKey(feature)
		if norm == "" {
			continue
		}
		if _, ok := seen[norm]; ok {
			continue
		}
		seen[norm] = struct{}{}
		details.RawFeature = append(details.RawFeature, norm)
		details.Features[norm] = struct{}{}
	}
	sort.Strings(details.RawFeature)
	return details
}

func buildEntitlementDenyPolicyResponse(
	provider *ProviderTarget,
	details entitlementRequestDetails,
	requiredFeatures []string,
	missingFeatures []string,
	violationCodes []string,
	violationMessages []string,
) map[string]interface{} {
	reasons := make([]map[string]interface{}, 0, len(violationCodes))
	for i, code := range violationCodes {
		message := "AIMXS entitlement validation failed"
		if i < len(violationMessages) && strings.TrimSpace(violationMessages[i]) != "" {
			message = violationMessages[i]
		}
		reasons = append(reasons, map[string]interface{}{
			"code":    code,
			"message": message,
		})
	}
	return map[string]interface{}{
		"decision": "DENY",
		"reasons":  reasons,
		"policyBundle": map[string]interface{}{
			"policyId":      "runtime-entitlement",
			"policyVersion": "v1alpha1",
		},
		"output": map[string]interface{}{
			"engine":           "runtime-entitlement",
			"providerName":     provider.Name,
			"providerId":       provider.ProviderID,
			"sku":              details.SKU,
			"tokenPresent":     strings.TrimSpace(details.Token) != "",
			"features":         sortedSetKeys(details.Features),
			"requiredFeatures": requiredFeatures,
			"missingFeatures":  missingFeatures,
		},
	}
}

func nestedValue(m map[string]interface{}, path ...string) interface{} {
	if len(path) == 0 || len(m) == 0 {
		return nil
	}
	var current interface{} = m
	for _, segment := range path {
		switch obj := current.(type) {
		case map[string]interface{}:
			next, exists := obj[segment]
			if !exists {
				return nil
			}
			current = next
		case JSONObject:
			next, exists := obj[segment]
			if !exists {
				return nil
			}
			current = next
		default:
			return nil
		}
	}
	return current
}

func nestedStringValue(m map[string]interface{}, path ...string) string {
	return stringValue(nestedValue(m, path...))
}

func stringValue(v interface{}) string {
	switch typed := v.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return ""
	}
}

func entitlementFeaturesFromValue(v interface{}) []string {
	switch typed := v.(type) {
	case nil:
		return nil
	case string:
		raw := strings.TrimSpace(typed)
		if raw == "" {
			return nil
		}
		parts := strings.FieldsFunc(raw, func(r rune) bool {
			return r == ',' || r == ';'
		})
		out := make([]string, 0, len(parts))
		for _, part := range parts {
			part = strings.TrimSpace(part)
			if part != "" {
				out = append(out, part)
			}
		}
		if len(out) == 0 {
			out = append(out, raw)
		}
		return out
	case []string:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if trimmed := strings.TrimSpace(item); trimmed != "" {
				out = append(out, trimmed)
			}
		}
		return out
	case []interface{}:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if trimmed := strings.TrimSpace(stringValue(item)); trimmed != "" {
				out = append(out, trimmed)
			}
		}
		return out
	case map[string]interface{}:
		out := make([]string, 0, len(typed))
		for key, val := range typed {
			if boolVal, ok := val.(bool); ok && !boolVal {
				continue
			}
			if strVal, ok := val.(string); ok {
				if strings.EqualFold(strings.TrimSpace(strVal), "false") {
					continue
				}
			}
			if strings.TrimSpace(key) != "" {
				out = append(out, key)
			}
		}
		return out
	case JSONObject:
		return entitlementFeaturesFromValue(map[string]interface{}(typed))
	default:
		if trimmed := strings.TrimSpace(stringValue(v)); trimmed != "" {
			return []string{trimmed}
		}
		return nil
	}
}

func normalizeEntitlementKey(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}

func sortedSetKeys(set map[string]struct{}) []string {
	if len(set) == 0 {
		return nil
	}
	out := make([]string, 0, len(set))
	for key := range set {
		if strings.TrimSpace(key) != "" {
			out = append(out, key)
		}
	}
	sort.Strings(out)
	return out
}

func stableRolloutBucket(parts ...string) int {
	s := strings.Join(parts, "|")
	sum := sha256.Sum256([]byte(s))
	// Use first two bytes for a stable 0-99 bucket.
	v := int(sum[0])<<8 | int(sum[1])
	return v % 100
}

func extractPolicyBundleRef(policyResp map[string]interface{}) PolicyBundleRef {
	out := PolicyBundleRef{}
	if policyResp == nil {
		return out
	}
	if m, ok := policyResp["policyBundle"].(map[string]interface{}); ok {
		out.PolicyID = strings.TrimSpace(policyValueToString(m["policyId"]))
		out.PolicyVersion = strings.TrimSpace(policyValueToString(m["policyVersion"]))
		out.Checksum = strings.TrimSpace(policyValueToString(m["checksum"]))
	}
	if out.PolicyID == "" {
		out.PolicyID = strings.TrimSpace(policyValueToString(policyResp["policyId"]))
	}
	if out.PolicyVersion == "" {
		out.PolicyVersion = strings.TrimSpace(policyValueToString(policyResp["policyVersion"]))
	}
	if out.Checksum == "" {
		out.Checksum = strings.TrimSpace(policyValueToString(policyResp["policyChecksum"]))
	}
	return out
}

func comparePolicyVersions(a, b string) int {
	normalize := func(v string) []string {
		v = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(strings.ToLower(v), "version-"), "v"))
		v = strings.ReplaceAll(v, "-", ".")
		v = strings.ReplaceAll(v, "_", ".")
		parts := strings.Split(v, ".")
		out := make([]string, 0, len(parts))
		for _, p := range parts {
			p = strings.TrimSpace(p)
			if p != "" {
				out = append(out, p)
			}
		}
		return out
	}

	ap := normalize(a)
	bp := normalize(b)
	n := len(ap)
	if len(bp) > n {
		n = len(bp)
	}
	for i := 0; i < n; i++ {
		av := "0"
		bv := "0"
		if i < len(ap) {
			av = ap[i]
		}
		if i < len(bp) {
			bv = bp[i]
		}
		ai, aErr := strconv.Atoi(av)
		bi, bErr := strconv.Atoi(bv)
		switch {
		case aErr == nil && bErr == nil:
			if ai < bi {
				return -1
			}
			if ai > bi {
				return 1
			}
		default:
			if av < bv {
				return -1
			}
			if av > bv {
				return 1
			}
		}
	}
	return 0
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
