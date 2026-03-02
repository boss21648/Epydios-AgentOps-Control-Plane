package runtime

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	runtimeMetricsOnce sync.Once

	runtimeHTTPRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "epydios_runtime_http_requests_total",
			Help: "Total runtime API requests partitioned by method/path/status.",
		},
		[]string{"method", "path", "status_class", "status_code"},
	)

	runtimeHTTPRequestDurationSeconds = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "epydios_runtime_http_request_duration_seconds",
			Help:    "Runtime API request latency in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "path"},
	)

	runtimeRunExecutionsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "epydios_runtime_run_executions_total",
			Help: "Total runtime run execution outcomes and policy decisions.",
		},
		[]string{"outcome", "decision"},
	)

	runtimeRunExecutionDurationSeconds = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "epydios_runtime_run_execution_duration_seconds",
			Help:    "Runtime run execution duration in seconds.",
			Buckets: []float64{0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 30, 45, 60},
		},
		[]string{"outcome", "decision"},
	)

	runtimeProviderCallsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "epydios_runtime_provider_calls_total",
			Help: "Total runtime provider call outcomes.",
		},
		[]string{"provider_type", "operation", "outcome"},
	)

	runtimeProviderCallDurationSeconds = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "epydios_runtime_provider_call_duration_seconds",
			Help:    "Runtime provider call latency in seconds.",
			Buckets: []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10},
		},
		[]string{"provider_type", "operation", "outcome"},
	)
)

func initRuntimeMetrics() {
	runtimeMetricsOnce.Do(func() {
		prometheus.MustRegister(
			runtimeHTTPRequestsTotal,
			runtimeHTTPRequestDurationSeconds,
			runtimeRunExecutionsTotal,
			runtimeRunExecutionDurationSeconds,
			runtimeProviderCallsTotal,
			runtimeProviderCallDurationSeconds,
		)
	})
}

func observeRuntimeHTTPRequest(method, path string, statusCode int, elapsed time.Duration) {
	initRuntimeMetrics()
	labelMethod := strings.ToUpper(strings.TrimSpace(method))
	if labelMethod == "" {
		labelMethod = "UNKNOWN"
	}
	labelPath := normalizeRuntimeHTTPPath(path)
	labelClass := statusCodeClass(statusCode)
	labelCode := strconv.Itoa(statusCode)

	runtimeHTTPRequestsTotal.WithLabelValues(labelMethod, labelPath, labelClass, labelCode).Inc()
	runtimeHTTPRequestDurationSeconds.WithLabelValues(labelMethod, labelPath).Observe(elapsed.Seconds())
}

func observeRuntimeRunExecution(outcome, decision string, elapsed time.Duration) {
	initRuntimeMetrics()
	labelOutcome := normalizeRunOutcome(outcome)
	labelDecision := normalizeRunDecision(decision)

	runtimeRunExecutionsTotal.WithLabelValues(labelOutcome, labelDecision).Inc()
	runtimeRunExecutionDurationSeconds.WithLabelValues(labelOutcome, labelDecision).Observe(elapsed.Seconds())
}

func observeRuntimeProviderCall(providerType, operation string, err error, elapsed time.Duration) {
	initRuntimeMetrics()
	labelProviderType := normalizeProviderType(providerType)
	labelOperation := normalizeProviderOperation(operation)
	labelOutcome := "success"
	if err != nil {
		labelOutcome = "error"
	}

	runtimeProviderCallsTotal.WithLabelValues(labelProviderType, labelOperation, labelOutcome).Inc()
	runtimeProviderCallDurationSeconds.WithLabelValues(labelProviderType, labelOperation, labelOutcome).Observe(elapsed.Seconds())
}

func normalizeRuntimeHTTPPath(path string) string {
	normalized := strings.TrimSpace(path)
	if normalized == "" {
		return "/unknown"
	}
	switch normalized {
	case "/healthz",
		"/metrics",
		"/v1alpha1/runtime/runs",
		"/v1alpha1/runtime/runs/export",
		"/v1alpha1/runtime/runs/retention/prune",
		"/v1alpha1/runtime/audit/events":
		return normalized
	}
	if strings.HasPrefix(normalized, "/v1alpha1/runtime/runs/") {
		return "/v1alpha1/runtime/runs/:id"
	}
	if strings.HasPrefix(normalized, "/v1alpha1/runtime/") {
		return "/v1alpha1/runtime/other"
	}
	return normalized
}

func statusCodeClass(code int) string {
	switch {
	case code >= http.StatusInternalServerError:
		return "5xx"
	case code >= http.StatusBadRequest:
		return "4xx"
	case code >= http.StatusMultipleChoices:
		return "3xx"
	case code >= http.StatusOK:
		return "2xx"
	default:
		return "1xx"
	}
}

func normalizeRunOutcome(outcome string) string {
	switch strings.ToLower(strings.TrimSpace(outcome)) {
	case "completed", "failed", "rejected":
		return strings.ToLower(strings.TrimSpace(outcome))
	default:
		return "other"
	}
}

func normalizeRunDecision(decision string) string {
	switch strings.ToUpper(strings.TrimSpace(decision)) {
	case "ALLOW", "DENY":
		return strings.ToUpper(strings.TrimSpace(decision))
	default:
		return "UNKNOWN"
	}
}

func normalizeProviderType(providerType string) string {
	normalized := strings.ToLower(strings.TrimSpace(providerType))
	if normalized == "" {
		return "unknown"
	}
	return normalized
}

func normalizeProviderOperation(operation string) string {
	normalized := strings.ToLower(strings.TrimSpace(operation))
	if normalized == "" {
		return "unknown"
	}
	return normalized
}
