package runtime

import (
	"encoding/json"
	"time"
)

type JSONObject map[string]interface{}

type RunStatus string

const (
	RunStatusPending          RunStatus = "PENDING"
	RunStatusProfileResolved  RunStatus = "PROFILE_RESOLVED"
	RunStatusPolicyEvaluated  RunStatus = "POLICY_EVALUATED"
	RunStatusEvidenceRecorded RunStatus = "EVIDENCE_RECORDED"
	RunStatusCompleted        RunStatus = "COMPLETED"
	RunStatusFailed           RunStatus = "FAILED"
)

type ObjectMeta struct {
	RequestID   string     `json:"requestId"`
	Timestamp   *time.Time `json:"timestamp,omitempty"`
	TenantID    string     `json:"tenantId,omitempty"`
	ProjectID   string     `json:"projectId,omitempty"`
	Environment string     `json:"environment,omitempty"`
	Actor       JSONObject `json:"actor,omitempty"`
}

type RunCreateRequest struct {
	Meta           ObjectMeta `json:"meta"`
	Subject        JSONObject `json:"subject"`
	Action         JSONObject `json:"action"`
	Resource       JSONObject `json:"resource,omitempty"`
	Task           JSONObject `json:"task,omitempty"`
	Defaults       JSONObject `json:"defaults,omitempty"`
	Context        JSONObject `json:"context,omitempty"`
	Mode           string     `json:"mode,omitempty"`
	DryRun         bool       `json:"dryRun,omitempty"`
	RetentionClass string     `json:"retentionClass,omitempty"`
	Profile        JSONObject `json:"profile,omitempty"`
	Workload       JSONObject `json:"workload,omitempty"`
	Annotations    JSONObject `json:"annotations,omitempty"`
}

type RunRecord struct {
	RunID                    string          `json:"runId"`
	RequestID                string          `json:"requestId"`
	TenantID                 string          `json:"tenantId,omitempty"`
	ProjectID                string          `json:"projectId,omitempty"`
	Environment              string          `json:"environment,omitempty"`
	Status                   RunStatus       `json:"status"`
	SelectedProfileProvider  string          `json:"selectedProfileProvider,omitempty"`
	SelectedPolicyProvider   string          `json:"selectedPolicyProvider,omitempty"`
	SelectedEvidenceProvider string          `json:"selectedEvidenceProvider,omitempty"`
	PolicyDecision           string          `json:"policyDecision,omitempty"`
	PolicyGrantTokenPresent  bool            `json:"policyGrantTokenPresent,omitempty"`
	PolicyGrantTokenSHA256   string          `json:"policyGrantTokenSha256,omitempty"`
	RequestPayload           json.RawMessage `json:"requestPayload,omitempty"`
	ProfileResponse          json.RawMessage `json:"profileResponse,omitempty"`
	PolicyResponse           json.RawMessage `json:"policyResponse,omitempty"`
	EvidenceRecordResponse   json.RawMessage `json:"evidenceRecordResponse,omitempty"`
	EvidenceBundleResponse   json.RawMessage `json:"evidenceBundleResponse,omitempty"`
	ErrorMessage             string          `json:"errorMessage,omitempty"`
	CreatedAt                time.Time       `json:"createdAt"`
	UpdatedAt                time.Time       `json:"updatedAt"`
}

type RunSummary struct {
	RunID                    string    `json:"runId"`
	RequestID                string    `json:"requestId"`
	TenantID                 string    `json:"tenantId,omitempty"`
	ProjectID                string    `json:"projectId,omitempty"`
	Environment              string    `json:"environment,omitempty"`
	Status                   RunStatus `json:"status"`
	SelectedProfileProvider  string    `json:"selectedProfileProvider,omitempty"`
	SelectedPolicyProvider   string    `json:"selectedPolicyProvider,omitempty"`
	SelectedEvidenceProvider string    `json:"selectedEvidenceProvider,omitempty"`
	PolicyDecision           string    `json:"policyDecision,omitempty"`
	PolicyGrantTokenPresent  bool      `json:"policyGrantTokenPresent,omitempty"`
	PolicyGrantTokenSHA256   string    `json:"policyGrantTokenSha256,omitempty"`
	CreatedAt                time.Time `json:"createdAt"`
	UpdatedAt                time.Time `json:"updatedAt"`
}

type APIError struct {
	ErrorCode string                 `json:"errorCode"`
	Message   string                 `json:"message"`
	Retryable bool                   `json:"retryable"`
	Details   map[string]interface{} `json:"details,omitempty"`
}
