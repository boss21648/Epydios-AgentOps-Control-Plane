package extensionprovider

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var extensionProviderGVK = schema.GroupVersionKind{
	Group:   "controlplane.epydios.ai",
	Version: "v1alpha1",
	Kind:    "ExtensionProvider",
}

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Log    logr.Logger
}

type probeResult struct {
	ProviderID      string
	ContractVersion string
	Capabilities    []string
	ProviderType    string
	ProviderVersion string
}

type capabilitiesResponse struct {
	ProviderType    string   `json:"providerType"`
	ProviderID      string   `json:"providerId"`
	ContractVersion string   `json:"contractVersion"`
	ProviderVersion string   `json:"providerVersion"`
	Capabilities    []string `json:"capabilities"`
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(extensionProviderGVK)

	return ctrl.NewControllerManagedBy(mgr).
		For(obj).
		Complete(r)
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := r.withLogger().WithValues("extensionProvider", req.NamespacedName.String())

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(extensionProviderGVK)
	if err := r.Get(ctx, req.NamespacedName, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	spec, _, _ := unstructured.NestedMap(obj.Object, "spec")
	probe, probeErr := r.probeExtensionProvider(ctx, req.Namespace, spec)
	if probeErr != nil {
		logger.Error(probeErr, "provider probe failed")
		if err := r.updateStatus(ctx, obj, nil, probeErr); err != nil {
			logger.Error(err, "failed to update provider status after probe failure")
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.updateStatus(ctx, obj, probe, nil); err != nil {
		return ctrl.Result{}, err
	}

	logger.Info("provider probe succeeded", "providerId", probe.ProviderID, "capabilities", len(probe.Capabilities))
	return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

func (r *Reconciler) probeExtensionProvider(ctx context.Context, namespace string, spec map[string]interface{}) (*probeResult, error) {
	providerType, _, _ := unstructured.NestedString(spec, "providerType")
	contractVersion, _, _ := unstructured.NestedString(spec, "contractVersion")
	endpointURL, _, _ := unstructured.NestedString(spec, "endpoint", "url")
	healthPath, _, _ := unstructured.NestedString(spec, "endpoint", "healthPath")
	capabilitiesPath, _, _ := unstructured.NestedString(spec, "endpoint", "capabilitiesPath")
	timeoutSeconds, found, _ := unstructured.NestedInt64(spec, "endpoint", "timeoutSeconds")
	if !found || timeoutSeconds <= 0 {
		timeoutSeconds = 10
	}
	if healthPath == "" {
		healthPath = "/healthz"
	}
	if capabilitiesPath == "" {
		capabilitiesPath = "/v1alpha1/capabilities"
	}
	if endpointURL == "" {
		return nil, fmt.Errorf("spec.endpoint.url is required")
	}

	baseURL, err := url.Parse(endpointURL)
	if err != nil {
		return nil, fmt.Errorf("invalid endpoint URL: %w", err)
	}

	authMode, _, _ := unstructured.NestedString(spec, "auth", "mode")
	headers := http.Header{}
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}
	switch authMode {
	case "", "None":
	case "BearerTokenSecret":
		token, err := r.readBearerTokenFromSpec(ctx, namespace, spec)
		if err != nil {
			return nil, err
		}
		headers.Set("Authorization", "Bearer "+token)
	case "MTLS":
		if !strings.EqualFold(baseURL.Scheme, "https") {
			return nil, fmt.Errorf("auth mode %q requires an https endpoint URL", authMode)
		}
		tlsCfg, err = r.buildMutualTLSConfig(ctx, namespace, spec)
		if err != nil {
			return nil, err
		}
	case "MTLSAndBearerTokenSecret":
		if !strings.EqualFold(baseURL.Scheme, "https") {
			return nil, fmt.Errorf("auth mode %q requires an https endpoint URL", authMode)
		}
		token, tokenErr := r.readBearerTokenFromSpec(ctx, namespace, spec)
		if tokenErr != nil {
			return nil, tokenErr
		}
		headers.Set("Authorization", "Bearer "+token)
		tlsCfg, err = r.buildMutualTLSConfig(ctx, namespace, spec)
		if err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("unsupported auth mode %q", authMode)
	}

	client := &http.Client{
		Timeout: time.Duration(timeoutSeconds) * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: tlsCfg,
		},
	}

	if err := doHealthCheck(ctx, client, baseURL, healthPath, headers); err != nil {
		return nil, err
	}
	cap, err := doCapabilitiesCheck(ctx, client, baseURL, capabilitiesPath, headers)
	if err != nil {
		return nil, err
	}

	if providerType != "" && cap.ProviderType != "" && providerType != cap.ProviderType {
		return nil, fmt.Errorf("provider type mismatch: spec=%s remote=%s", providerType, cap.ProviderType)
	}
	if contractVersion == "" {
		contractVersion = "v1alpha1"
	}
	if cap.ContractVersion != "" && contractVersion != cap.ContractVersion {
		return nil, fmt.Errorf("contract version mismatch: spec=%s remote=%s", contractVersion, cap.ContractVersion)
	}

	return &probeResult{
		ProviderID:      firstNonEmpty(cap.ProviderID, providerType+"-provider"),
		ProviderType:    cap.ProviderType,
		ProviderVersion: cap.ProviderVersion,
		ContractVersion: firstNonEmpty(cap.ContractVersion, contractVersion),
		Capabilities:    cap.Capabilities,
	}, nil
}

func (r *Reconciler) readBearerTokenFromSpec(ctx context.Context, namespace string, spec map[string]interface{}) (string, error) {
	secretName, _, _ := unstructured.NestedString(spec, "auth", "bearerTokenSecretRef", "name")
	secretKey, found, _ := unstructured.NestedString(spec, "auth", "bearerTokenSecretRef", "key")
	if !found || secretKey == "" {
		secretKey = "token"
	}
	return r.readSecretToken(ctx, namespace, secretName, secretKey)
}

func (r *Reconciler) readSecretToken(ctx context.Context, namespace, name, key string) (string, error) {
	if strings.TrimSpace(name) == "" {
		return "", fmt.Errorf("auth.bearerTokenSecretRef.name is required")
	}
	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, &secret); err != nil {
		return "", fmt.Errorf("read bearer token secret %s/%s: %w", namespace, name, err)
	}
	raw, ok := secret.Data[key]
	if !ok {
		return "", fmt.Errorf("bearer token secret key %q not found in %s/%s", key, namespace, name)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("bearer token secret %s/%s key %q is empty", namespace, name, key)
	}
	return token, nil
}

func (r *Reconciler) buildMutualTLSConfig(ctx context.Context, namespace string, spec map[string]interface{}) (*tls.Config, error) {
	clientTLSSecretName, _, _ := unstructured.NestedString(spec, "auth", "clientTLSSecretRef", "name")
	if strings.TrimSpace(clientTLSSecretName) == "" {
		return nil, fmt.Errorf("auth.clientTLSSecretRef.name is required for mTLS")
	}

	certPEM, err := r.readSecretData(ctx, namespace, clientTLSSecretName, "tls.crt")
	if err != nil {
		return nil, fmt.Errorf("read mTLS client certificate: %w", err)
	}
	keyPEM, err := r.readSecretData(ctx, namespace, clientTLSSecretName, "tls.key")
	if err != nil {
		return nil, fmt.Errorf("read mTLS client key: %w", err)
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse mTLS client keypair from secret %s/%s: %w", namespace, clientTLSSecretName, err)
	}

	tlsCfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
	}

	caSecretName, _, _ := unstructured.NestedString(spec, "auth", "caSecretRef", "name")
	if strings.TrimSpace(caSecretName) != "" {
		caPEM, err := r.readSecretDataWithFallbackKeys(ctx, namespace, caSecretName, "ca.crt", "tls.crt")
		if err != nil {
			return nil, fmt.Errorf("read mTLS CA bundle: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("parse mTLS CA bundle from secret %s/%s: no valid PEM certificates found", namespace, caSecretName)
		}
		tlsCfg.RootCAs = pool
	}

	return tlsCfg, nil
}

func (r *Reconciler) readSecretData(ctx context.Context, namespace, name, key string) ([]byte, error) {
	if strings.TrimSpace(name) == "" {
		return nil, fmt.Errorf("secret name is required")
	}
	if strings.TrimSpace(key) == "" {
		return nil, fmt.Errorf("secret key is required")
	}

	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, &secret); err != nil {
		return nil, fmt.Errorf("read secret %s/%s: %w", namespace, name, err)
	}
	raw, ok := secret.Data[key]
	if !ok {
		return nil, fmt.Errorf("secret key %q not found in %s/%s", key, namespace, name)
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("secret %s/%s key %q is empty", namespace, name, key)
	}
	return raw, nil
}

func (r *Reconciler) readSecretDataWithFallbackKeys(ctx context.Context, namespace, name string, keys ...string) ([]byte, error) {
	if strings.TrimSpace(name) == "" {
		return nil, fmt.Errorf("secret name is required")
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("at least one secret key is required")
	}

	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, &secret); err != nil {
		return nil, fmt.Errorf("read secret %s/%s: %w", namespace, name, err)
	}
	for _, key := range keys {
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		if raw, ok := secret.Data[key]; ok {
			if len(raw) == 0 {
				return nil, fmt.Errorf("secret %s/%s key %q is empty", namespace, name, key)
			}
			return raw, nil
		}
	}
	return nil, fmt.Errorf("none of the keys %q found in %s/%s", keys, namespace, name)
}

func doHealthCheck(ctx context.Context, c *http.Client, base *url.URL, path string, headers http.Header) error {
	u := *base
	u.Path = joinURLPath(base.Path, path)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header = headers.Clone()

	resp, err := c.Do(req)
	if err != nil {
		return fmt.Errorf("health probe request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("health probe status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

func doCapabilitiesCheck(ctx context.Context, c *http.Client, base *url.URL, path string, headers http.Header) (*capabilitiesResponse, error) {
	u := *base
	u.Path = joinURLPath(base.Path, path)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header = headers.Clone()

	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("capabilities request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("capabilities status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var out capabilitiesResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode capabilities response: %w", err)
	}
	return &out, nil
}

func (r *Reconciler) updateStatus(ctx context.Context, obj *unstructured.Unstructured, probe *probeResult, probeErr error) error {
	status, _, _ := unstructured.NestedMap(obj.Object, "status")
	if status == nil {
		status = map[string]interface{}{}
	}
	original := runtime.DeepCopyJSON(status)

	status["observedGeneration"] = obj.GetGeneration()

	if probe != nil {
		status["resolved"] = map[string]interface{}{
			"providerId":      probe.ProviderID,
			"contractVersion": probe.ContractVersion,
			"capabilities":    stringSliceToInterfaces(probe.Capabilities),
		}
		setCondition(status, metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionTrue,
			Reason:             "ProbeSucceeded",
			Message:            "Provider health and capabilities probes succeeded.",
			LastTransitionTime: metav1.Now(),
		})
		setCondition(status, metav1.Condition{
			Type:               "Probed",
			Status:             metav1.ConditionTrue,
			Reason:             "Success",
			Message:            "Provider probe completed successfully.",
			LastTransitionTime: metav1.Now(),
		})
	} else {
		delete(status, "resolved")
		setCondition(status, metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionFalse,
			Reason:             "ProbeFailed",
			Message:            truncate(probeErr.Error(), 512),
			LastTransitionTime: metav1.Now(),
		})
		setCondition(status, metav1.Condition{
			Type:               "Probed",
			Status:             metav1.ConditionFalse,
			Reason:             "Failure",
			Message:            truncate(probeErr.Error(), 512),
			LastTransitionTime: metav1.Now(),
		})
	}

	if reflect.DeepEqual(original, status) {
		return nil
	}

	if err := unstructured.SetNestedMap(obj.Object, status, "status"); err != nil {
		return err
	}
	return r.Status().Update(ctx, obj)
}

func setCondition(status map[string]interface{}, cond metav1.Condition) {
	raw, _, _ := unstructured.NestedSlice(status, "conditions")
	nowCond := map[string]interface{}{
		"type":               cond.Type,
		"status":             string(cond.Status),
		"reason":             cond.Reason,
		"message":            cond.Message,
		"lastTransitionTime": cond.LastTransitionTime.Format(time.RFC3339),
	}

	replaced := false
	for i, item := range raw {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if t, _ := m["type"].(string); t == cond.Type {
			if existingStatus, _ := m["status"].(string); existingStatus == string(cond.Status) {
				if existingReason, _ := m["reason"].(string); existingReason == cond.Reason {
					if existingMessage, _ := m["message"].(string); existingMessage == cond.Message {
						if existingTransition, ok := m["lastTransitionTime"]; ok {
							nowCond["lastTransitionTime"] = existingTransition
						}
					}
				}
			}
			raw[i] = nowCond
			replaced = true
			break
		}
	}
	if !replaced {
		raw = append(raw, nowCond)
	}
	status["conditions"] = raw
}

func joinURLPath(basePath, p string) string {
	if p == "" {
		return basePath
	}
	if strings.HasPrefix(p, "/") {
		return p
	}
	if strings.HasSuffix(basePath, "/") {
		return basePath + p
	}
	if basePath == "" {
		return "/" + p
	}
	return basePath + "/" + p
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n < 3 {
		return s[:n]
	}
	return s[:n-3] + "..."
}

func stringSliceToInterfaces(in []string) []interface{} {
	out := make([]interface{}, 0, len(in))
	for _, v := range in {
		out = append(out, v)
	}
	return out
}

func (r *Reconciler) withLogger() logr.Logger {
	if r.Log.GetSink() != nil {
		return r.Log
	}
	return ctrl.Log.WithName("ExtensionProvider")
}
