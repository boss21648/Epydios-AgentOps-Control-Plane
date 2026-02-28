package runtime

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type RunStore interface {
	Ping(context.Context) error
	EnsureSchema(context.Context) error
	UpsertRun(context.Context, *RunRecord) error
	GetRun(context.Context, string) (*RunRecord, error)
	ListRuns(context.Context, int) ([]RunSummary, error)
}

type PostgresRunStore struct {
	db *sql.DB
}

func NewPostgresRunStore(db *sql.DB) *PostgresRunStore {
	return &PostgresRunStore{db: db}
}

func (s *PostgresRunStore) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *PostgresRunStore) EnsureSchema(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS orchestration_runs (
			run_id TEXT PRIMARY KEY,
			request_id TEXT NOT NULL,
			tenant_id TEXT,
			project_id TEXT,
			environment TEXT,
			status TEXT NOT NULL,
			selected_profile_provider TEXT,
			selected_policy_provider TEXT,
			selected_evidence_provider TEXT,
			policy_decision TEXT,
			policy_grant_token_present BOOLEAN NOT NULL DEFAULT FALSE,
			policy_grant_token_sha256 TEXT,
			request_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
			profile_response JSONB,
			policy_response JSONB,
			evidence_record_response JSONB,
			evidence_bundle_response JSONB,
			error_message TEXT,
			created_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL
		)`,
		`ALTER TABLE orchestration_runs ADD COLUMN IF NOT EXISTS policy_grant_token_present BOOLEAN NOT NULL DEFAULT FALSE`,
		`ALTER TABLE orchestration_runs ADD COLUMN IF NOT EXISTS policy_grant_token_sha256 TEXT`,
		`CREATE INDEX IF NOT EXISTS idx_orchestration_runs_created_at ON orchestration_runs (created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_orchestration_runs_status ON orchestration_runs (status)`,
	}

	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("ensure schema: %w", err)
		}
	}
	return nil
}

func (s *PostgresRunStore) UpsertRun(ctx context.Context, run *RunRecord) error {
	const q = `
INSERT INTO orchestration_runs (
	run_id,
	request_id,
	tenant_id,
	project_id,
	environment,
	status,
	selected_profile_provider,
	selected_policy_provider,
	selected_evidence_provider,
	policy_decision,
	policy_grant_token_present,
	policy_grant_token_sha256,
	request_payload,
	profile_response,
	policy_response,
	evidence_record_response,
	evidence_bundle_response,
	error_message,
	created_at,
	updated_at
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
)
ON CONFLICT (run_id) DO UPDATE SET
	request_id = EXCLUDED.request_id,
	tenant_id = EXCLUDED.tenant_id,
	project_id = EXCLUDED.project_id,
	environment = EXCLUDED.environment,
	status = EXCLUDED.status,
	selected_profile_provider = EXCLUDED.selected_profile_provider,
	selected_policy_provider = EXCLUDED.selected_policy_provider,
	selected_evidence_provider = EXCLUDED.selected_evidence_provider,
	policy_decision = EXCLUDED.policy_decision,
	policy_grant_token_present = EXCLUDED.policy_grant_token_present,
	policy_grant_token_sha256 = EXCLUDED.policy_grant_token_sha256,
	request_payload = EXCLUDED.request_payload,
	profile_response = EXCLUDED.profile_response,
	policy_response = EXCLUDED.policy_response,
	evidence_record_response = EXCLUDED.evidence_record_response,
	evidence_bundle_response = EXCLUDED.evidence_bundle_response,
	error_message = EXCLUDED.error_message,
	updated_at = EXCLUDED.updated_at
`

	createdAt := run.CreatedAt.UTC()
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
		run.CreatedAt = createdAt
	}
	updatedAt := run.UpdatedAt.UTC()
	if updatedAt.IsZero() {
		updatedAt = createdAt
		run.UpdatedAt = updatedAt
	}

	_, err := s.db.ExecContext(
		ctx,
		q,
		run.RunID,
		run.RequestID,
		nullStr(run.TenantID),
		nullStr(run.ProjectID),
		nullStr(run.Environment),
		string(run.Status),
		nullStr(run.SelectedProfileProvider),
		nullStr(run.SelectedPolicyProvider),
		nullStr(run.SelectedEvidenceProvider),
		nullStr(run.PolicyDecision),
		run.PolicyGrantTokenPresent,
		nullStr(run.PolicyGrantTokenSHA256),
		jsonBytesOrEmptyObject(run.RequestPayload),
		nullJSON(run.ProfileResponse),
		nullJSON(run.PolicyResponse),
		nullJSON(run.EvidenceRecordResponse),
		nullJSON(run.EvidenceBundleResponse),
		nullStr(run.ErrorMessage),
		createdAt,
		updatedAt,
	)
	if err != nil {
		return fmt.Errorf("upsert run %s: %w", run.RunID, err)
	}
	return nil
}

func (s *PostgresRunStore) GetRun(ctx context.Context, runID string) (*RunRecord, error) {
	const q = `
SELECT
	run_id,
	request_id,
	COALESCE(tenant_id, ''),
	COALESCE(project_id, ''),
	COALESCE(environment, ''),
	status,
	COALESCE(selected_profile_provider, ''),
	COALESCE(selected_policy_provider, ''),
	COALESCE(selected_evidence_provider, ''),
	COALESCE(policy_decision, ''),
	COALESCE(policy_grant_token_present, FALSE),
	COALESCE(policy_grant_token_sha256, ''),
	request_payload,
	profile_response,
	policy_response,
	evidence_record_response,
	evidence_bundle_response,
	COALESCE(error_message, ''),
	created_at,
	updated_at
FROM orchestration_runs
WHERE run_id = $1
`

	var (
		rec     RunRecord
		status  string
		reqJSON []byte
		pJSON   []byte
		polJSON []byte
		erJSON  []byte
		ebJSON  []byte
	)

	err := s.db.QueryRowContext(ctx, q, runID).Scan(
		&rec.RunID,
		&rec.RequestID,
		&rec.TenantID,
		&rec.ProjectID,
		&rec.Environment,
		&status,
		&rec.SelectedProfileProvider,
		&rec.SelectedPolicyProvider,
		&rec.SelectedEvidenceProvider,
		&rec.PolicyDecision,
		&rec.PolicyGrantTokenPresent,
		&rec.PolicyGrantTokenSHA256,
		&reqJSON,
		&pJSON,
		&polJSON,
		&erJSON,
		&ebJSON,
		&rec.ErrorMessage,
		&rec.CreatedAt,
		&rec.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	rec.Status = RunStatus(status)
	rec.RequestPayload = reqJSON
	rec.ProfileResponse = pJSON
	rec.PolicyResponse = polJSON
	rec.EvidenceRecordResponse = erJSON
	rec.EvidenceBundleResponse = ebJSON

	return &rec, nil
}

func (s *PostgresRunStore) ListRuns(ctx context.Context, limit int) ([]RunSummary, error) {
	if limit <= 0 {
		limit = 25
	}
	if limit > 200 {
		limit = 200
	}

	const q = `
SELECT
	run_id,
	request_id,
	COALESCE(tenant_id, ''),
	COALESCE(project_id, ''),
	COALESCE(environment, ''),
	status,
	COALESCE(selected_profile_provider, ''),
	COALESCE(selected_policy_provider, ''),
	COALESCE(selected_evidence_provider, ''),
	COALESCE(policy_decision, ''),
	COALESCE(policy_grant_token_present, FALSE),
	COALESCE(policy_grant_token_sha256, ''),
	created_at,
	updated_at
FROM orchestration_runs
ORDER BY created_at DESC
LIMIT $1
`

	rows, err := s.db.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]RunSummary, 0, limit)
	for rows.Next() {
		var (
			item   RunSummary
			status string
		)
		if err := rows.Scan(
			&item.RunID,
			&item.RequestID,
			&item.TenantID,
			&item.ProjectID,
			&item.Environment,
			&status,
			&item.SelectedProfileProvider,
			&item.SelectedPolicyProvider,
			&item.SelectedEvidenceProvider,
			&item.PolicyDecision,
			&item.PolicyGrantTokenPresent,
			&item.PolicyGrantTokenSHA256,
			&item.CreatedAt,
			&item.UpdatedAt,
		); err != nil {
			return nil, err
		}
		item.Status = RunStatus(status)
		out = append(out, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func nullStr(v string) interface{} {
	if v == "" {
		return nil
	}
	return v
}

func nullJSON(v []byte) interface{} {
	if len(v) == 0 {
		return nil
	}
	return v
}

func jsonBytesOrEmptyObject(v []byte) []byte {
	if len(v) == 0 {
		return []byte("{}")
	}
	return v
}
