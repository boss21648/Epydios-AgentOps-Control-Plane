package runtime

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"
)

const defaultAuditBufferCapacity = 2000

type RuntimeAuditQuery struct {
	Limit      int
	TenantID   string
	ProjectID  string
	ProviderID string
	Decision   string
	Event      string
}

type runtimeAuditBuffer struct {
	mu       sync.RWMutex
	capacity int
	items    []map[string]interface{}
}

var globalRuntimeAuditBuffer = newRuntimeAuditBuffer(defaultAuditBufferCapacity)

func newRuntimeAuditBuffer(capacity int) *runtimeAuditBuffer {
	if capacity <= 0 {
		capacity = defaultAuditBufferCapacity
	}
	return &runtimeAuditBuffer{
		capacity: capacity,
		items:    make([]map[string]interface{}, 0, capacity),
	}
}

func (b *runtimeAuditBuffer) append(record map[string]interface{}) {
	if b == nil || len(record) == 0 {
		return
	}
	copied := cloneInterfaceMap(record)

	b.mu.Lock()
	defer b.mu.Unlock()

	b.items = append(b.items, copied)
	if overflow := len(b.items) - b.capacity; overflow > 0 {
		copy(b.items, b.items[overflow:])
		b.items = b.items[:b.capacity]
	}
}

func (b *runtimeAuditBuffer) snapshot() []map[string]interface{} {
	if b == nil {
		return nil
	}
	b.mu.RLock()
	defer b.mu.RUnlock()

	out := make([]map[string]interface{}, len(b.items))
	for i := range b.items {
		out[i] = cloneInterfaceMap(b.items[i])
	}
	return out
}

func ListRuntimeAuditEvents(query RuntimeAuditQuery) []map[string]interface{} {
	items := globalRuntimeAuditBuffer.snapshot()
	if len(items) == 0 {
		return []map[string]interface{}{}
	}
	limit := query.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}

	tenantNeedle := strings.TrimSpace(query.TenantID)
	projectNeedle := strings.TrimSpace(query.ProjectID)
	providerNeedle := strings.TrimSpace(query.ProviderID)
	decisionNeedle := strings.ToUpper(strings.TrimSpace(query.Decision))
	eventNeedle := strings.ToLower(strings.TrimSpace(query.Event))

	out := make([]map[string]interface{}, 0, limit)
	for i := len(items) - 1; i >= 0; i-- {
		record := items[i]
		if !runtimeAuditRecordMatches(record, tenantNeedle, projectNeedle, providerNeedle, decisionNeedle, eventNeedle) {
			continue
		}
		out = append(out, cloneInterfaceMap(record))
		if len(out) >= limit {
			break
		}
	}
	return out
}

func runtimeAuditRecordMatches(record map[string]interface{}, tenantID, projectID, providerID, decision, event string) bool {
	if len(record) == 0 {
		return false
	}
	if tenantID != "" && runtimeAuditRecordString(record, "tenantId") != tenantID {
		return false
	}
	if projectID != "" && runtimeAuditRecordString(record, "projectId") != projectID {
		return false
	}
	if providerID != "" {
		providerValue := runtimeAuditRecordString(record, "providerId", "policyProvider", "profileProvider", "evidenceProvider")
		if providerValue != providerID {
			return false
		}
	}
	if decision != "" {
		if strings.ToUpper(runtimeAuditRecordString(record, "decision", "policy")) != decision {
			return false
		}
	}
	if event != "" {
		recordEvent := strings.ToLower(runtimeAuditRecordString(record, "event"))
		if !strings.Contains(recordEvent, event) {
			return false
		}
	}
	return true
}

func runtimeAuditRecordString(record map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		val, ok := record[key]
		if !ok {
			continue
		}
		switch typed := val.(type) {
		case string:
			return strings.TrimSpace(typed)
		case []byte:
			return strings.TrimSpace(string(typed))
		}
	}
	return ""
}

func cloneInterfaceMap(in map[string]interface{}) map[string]interface{} {
	if in == nil {
		return nil
	}
	out := make(map[string]interface{}, len(in))
	for k, v := range in {
		out[k] = cloneInterfaceValue(v)
	}
	return out
}

func cloneInterfaceValue(v interface{}) interface{} {
	switch typed := v.(type) {
	case map[string]interface{}:
		return cloneInterfaceMap(typed)
	case []interface{}:
		out := make([]interface{}, len(typed))
		for i := range typed {
			out[i] = cloneInterfaceValue(typed[i])
		}
		return out
	case []string:
		out := make([]string, len(typed))
		copy(out, typed)
		return out
	default:
		return typed
	}
}

func emitAuditEvent(ctx context.Context, event string, fields map[string]interface{}) {
	if event == "" {
		return
	}

	record := map[string]interface{}{
		"ts":        time.Now().UTC().Format(time.RFC3339Nano),
		"event":     event,
		"component": "runtime",
	}
	if identity, ok := RuntimeIdentityFromContext(ctx); ok && identity != nil {
		if identity.Subject != "" {
			record["subject"] = identity.Subject
		}
		if identity.ClientID != "" {
			record["clientId"] = identity.ClientID
		}
		if len(identity.Roles) > 0 {
			record["roles"] = identity.Roles
		}
		if len(identity.TenantIDs) > 0 {
			record["tenantScopes"] = identity.TenantIDs
		}
		if len(identity.ProjectIDs) > 0 {
			record["projectScopes"] = identity.ProjectIDs
		}
	}
	for k, v := range fields {
		if k == "" {
			continue
		}
		record[k] = v
	}

	raw, err := json.Marshal(record)
	if err != nil {
		log.Printf("AUDIT {\"event\":%q,\"marshalError\":%q}", event, err.Error())
	} else {
		log.Printf("AUDIT %s", raw)
	}
	globalRuntimeAuditBuffer.append(record)
}
