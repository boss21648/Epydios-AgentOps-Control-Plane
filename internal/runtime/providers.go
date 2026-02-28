package runtime

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var extensionProviderGVK = schema.GroupVersionKind{
	Group:   "controlplane.epydios.ai",
	Version: "v1alpha1",
	Kind:    "ExtensionProvider",
}

var extensionProviderListGVK = schema.GroupVersionKind{
	Group:   "controlplane.epydios.ai",
	Version: "v1alpha1",
	Kind:    "ExtensionProviderList",
}

type ProviderTarget struct {
	Name           string
	Namespace      string
	ProviderType   string
	ProviderID     string
	EndpointURL    string
	TimeoutSeconds int64
	Priority       int64
	AuthMode       string

	BearerSecretName string
	BearerSecretKey  string
	ClientTLSSecret  string
	CASecret         string
}

type ProviderRegistry struct {
	k8s client.Client
}

func NewProviderRegistry(k8s client.Client) *ProviderRegistry {
	return &ProviderRegistry{k8s: k8s}
}

func (r *ProviderRegistry) SelectProvider(ctx context.Context, namespace, providerType, requiredCapability string, minPriority int64) (*ProviderTarget, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(extensionProviderListGVK)
	if err := r.k8s.List(ctx, list, client.InNamespace(namespace)); err != nil {
		return nil, fmt.Errorf("list ExtensionProvider: %w", err)
	}

	candidates := make([]ProviderTarget, 0, len(list.Items))
	for _, item := range list.Items {
		spec, _, _ := unstructured.NestedMap(item.Object, "spec")
		status, _, _ := unstructured.NestedMap(item.Object, "status")

		ptype, _, _ := unstructured.NestedString(spec, "providerType")
		if ptype != providerType {
			continue
		}

		enabled, found, _ := unstructured.NestedBool(spec, "selection", "enabled")
		if !found {
			enabled = true
		}
		if !enabled {
			continue
		}

		priority, found, _ := unstructured.NestedInt64(spec, "selection", "priority")
		if !found {
			priority = 100
		}
		if priority < minPriority {
			continue
		}

		if !hasConditionTrue(status, "Ready") || !hasConditionTrue(status, "Probed") {
			continue
		}

		caps := resolvedCapabilities(status)
		if len(caps) == 0 {
			caps = advertisedCapabilities(spec)
		}
		if requiredCapability != "" && !containsString(caps, requiredCapability) {
			continue
		}

		endpointURL, _, _ := unstructured.NestedString(spec, "endpoint", "url")
		if strings.TrimSpace(endpointURL) == "" {
			continue
		}
		timeoutSeconds, found, _ := unstructured.NestedInt64(spec, "endpoint", "timeoutSeconds")
		if !found || timeoutSeconds <= 0 {
			timeoutSeconds = 10
		}

		providerID, _, _ := unstructured.NestedString(status, "resolved", "providerId")
		if strings.TrimSpace(providerID) == "" {
			providerID, _, _ = unstructured.NestedString(spec, "providerId")
		}
		if strings.TrimSpace(providerID) == "" {
			providerID = item.GetName()
		}

		authMode, _, _ := unstructured.NestedString(spec, "auth", "mode")
		bearerName, _, _ := unstructured.NestedString(spec, "auth", "bearerTokenSecretRef", "name")
		bearerKey, found, _ := unstructured.NestedString(spec, "auth", "bearerTokenSecretRef", "key")
		if !found || bearerKey == "" {
			bearerKey = "token"
		}
		clientTLSSecret, _, _ := unstructured.NestedString(spec, "auth", "clientTLSSecretRef", "name")
		caSecret, _, _ := unstructured.NestedString(spec, "auth", "caSecretRef", "name")

		candidates = append(candidates, ProviderTarget{
			Name:             item.GetName(),
			Namespace:        item.GetNamespace(),
			ProviderType:     ptype,
			ProviderID:       providerID,
			EndpointURL:      endpointURL,
			TimeoutSeconds:   timeoutSeconds,
			Priority:         priority,
			AuthMode:         firstNonEmpty(authMode, "None"),
			BearerSecretName: bearerName,
			BearerSecretKey:  bearerKey,
			ClientTLSSecret:  clientTLSSecret,
			CASecret:         caSecret,
		})
	}

	if len(candidates) == 0 {
		return nil, fmt.Errorf("no provider found (type=%s capability=%s minPriority=%d)", providerType, requiredCapability, minPriority)
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].Priority != candidates[j].Priority {
			return candidates[i].Priority > candidates[j].Priority
		}
		return candidates[i].Name < candidates[j].Name
	})

	chosen := candidates[0]
	return &chosen, nil
}

func (r *ProviderRegistry) PostJSON(ctx context.Context, target *ProviderTarget, path string, reqBody interface{}, out interface{}) error {
	baseURL, err := url.Parse(target.EndpointURL)
	if err != nil {
		return fmt.Errorf("invalid provider endpoint URL %q: %w", target.EndpointURL, err)
	}
	reqURL := *baseURL
	reqURL.Path = joinURLPath(baseURL.Path, path)

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return fmt.Errorf("marshal provider request: %w", err)
	}

	clientHTTP, headers, err := r.httpClientAndHeaders(ctx, target, reqURL.Scheme)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, reqURL.String(), bytes.NewReader(bodyBytes))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, vals := range headers {
		for _, v := range vals {
			req.Header.Add(k, v)
		}
	}

	resp, err := clientHTTP.Do(req)
	if err != nil {
		return fmt.Errorf("provider call failed %s: %w", reqURL.String(), err)
	}
	defer resp.Body.Close()
	respBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("provider call failed status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(respBytes)))
	}

	if out == nil {
		return nil
	}
	if err := json.Unmarshal(respBytes, out); err != nil {
		return fmt.Errorf("decode provider response: %w", err)
	}
	return nil
}

func (r *ProviderRegistry) httpClientAndHeaders(ctx context.Context, target *ProviderTarget, scheme string) (*http.Client, http.Header, error) {
	headers := make(http.Header)
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}

	switch target.AuthMode {
	case "", "None":
	case "BearerTokenSecret":
		token, err := r.readSecretToken(ctx, target.Namespace, target.BearerSecretName, target.BearerSecretKey)
		if err != nil {
			return nil, nil, err
		}
		headers.Set("Authorization", "Bearer "+token)
	case "MTLS":
		if !strings.EqualFold(scheme, "https") {
			return nil, nil, fmt.Errorf("auth mode %q requires https endpoint for provider %s", target.AuthMode, target.Name)
		}
		mtls, err := r.buildMutualTLSConfig(ctx, target)
		if err != nil {
			return nil, nil, err
		}
		tlsCfg = mtls
	case "MTLSAndBearerTokenSecret":
		if !strings.EqualFold(scheme, "https") {
			return nil, nil, fmt.Errorf("auth mode %q requires https endpoint for provider %s", target.AuthMode, target.Name)
		}
		token, err := r.readSecretToken(ctx, target.Namespace, target.BearerSecretName, target.BearerSecretKey)
		if err != nil {
			return nil, nil, err
		}
		headers.Set("Authorization", "Bearer "+token)
		mtls, err := r.buildMutualTLSConfig(ctx, target)
		if err != nil {
			return nil, nil, err
		}
		tlsCfg = mtls
	default:
		return nil, nil, fmt.Errorf("unsupported auth mode %q for provider %s", target.AuthMode, target.Name)
	}

	timeoutSeconds := target.TimeoutSeconds
	if timeoutSeconds <= 0 {
		timeoutSeconds = 10
	}
	httpClient := &http.Client{
		Timeout: time.Duration(timeoutSeconds) * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: tlsCfg,
		},
	}
	return httpClient, headers, nil
}

func (r *ProviderRegistry) readSecretToken(ctx context.Context, namespace, secretName, key string) (string, error) {
	if strings.TrimSpace(secretName) == "" {
		return "", fmt.Errorf("missing auth.bearerTokenSecretRef.name")
	}
	if strings.TrimSpace(key) == "" {
		key = "token"
	}
	var secret corev1.Secret
	if err := r.k8s.Get(ctx, types.NamespacedName{Namespace: namespace, Name: secretName}, &secret); err != nil {
		return "", fmt.Errorf("read secret %s/%s: %w", namespace, secretName, err)
	}
	raw, ok := secret.Data[key]
	if !ok {
		return "", fmt.Errorf("secret key %q not found in %s/%s", key, namespace, secretName)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("secret %s/%s key %q is empty", namespace, secretName, key)
	}
	return token, nil
}

func (r *ProviderRegistry) buildMutualTLSConfig(ctx context.Context, target *ProviderTarget) (*tls.Config, error) {
	if strings.TrimSpace(target.ClientTLSSecret) == "" {
		return nil, fmt.Errorf("missing auth.clientTLSSecretRef.name for provider %s", target.Name)
	}

	var clientSecret corev1.Secret
	if err := r.k8s.Get(ctx, types.NamespacedName{Namespace: target.Namespace, Name: target.ClientTLSSecret}, &clientSecret); err != nil {
		return nil, fmt.Errorf("read clientTLS secret %s/%s: %w", target.Namespace, target.ClientTLSSecret, err)
	}
	certPEM, ok := clientSecret.Data["tls.crt"]
	if !ok || len(certPEM) == 0 {
		return nil, fmt.Errorf("clientTLS secret %s/%s missing tls.crt", target.Namespace, target.ClientTLSSecret)
	}
	keyPEM, ok := clientSecret.Data["tls.key"]
	if !ok || len(keyPEM) == 0 {
		return nil, fmt.Errorf("clientTLS secret %s/%s missing tls.key", target.Namespace, target.ClientTLSSecret)
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse mTLS client keypair for %s: %w", target.Name, err)
	}

	cfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
	}
	if strings.TrimSpace(target.CASecret) == "" {
		return cfg, nil
	}

	var caSecret corev1.Secret
	if err := r.k8s.Get(ctx, types.NamespacedName{Namespace: target.Namespace, Name: target.CASecret}, &caSecret); err != nil {
		return nil, fmt.Errorf("read CA secret %s/%s: %w", target.Namespace, target.CASecret, err)
	}
	caPEM := caSecret.Data["ca.crt"]
	if len(caPEM) == 0 {
		caPEM = caSecret.Data["tls.crt"]
	}
	if len(caPEM) == 0 {
		return nil, fmt.Errorf("CA secret %s/%s missing ca.crt/tls.crt", target.Namespace, target.CASecret)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("parse CA bundle from %s/%s failed", target.Namespace, target.CASecret)
	}
	cfg.RootCAs = pool
	return cfg, nil
}

func hasConditionTrue(status map[string]interface{}, condType string) bool {
	conds, found, _ := unstructured.NestedSlice(status, "conditions")
	if !found {
		return false
	}
	for _, item := range conds {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		t, _ := m["type"].(string)
		s, _ := m["status"].(string)
		if t == condType && strings.EqualFold(s, "True") {
			return true
		}
	}
	return false
}

func resolvedCapabilities(status map[string]interface{}) []string {
	out := make([]string, 0)
	caps, found, _ := unstructured.NestedSlice(status, "resolved", "capabilities")
	if !found {
		return out
	}
	for _, item := range caps {
		if s, ok := item.(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}

func advertisedCapabilities(spec map[string]interface{}) []string {
	out := make([]string, 0)
	caps, found, _ := unstructured.NestedSlice(spec, "advertisedCapabilities")
	if !found {
		return out
	}
	for _, item := range caps {
		if s, ok := item.(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}

func containsString(items []string, target string) bool {
	for _, item := range items {
		if strings.EqualFold(item, target) {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
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
