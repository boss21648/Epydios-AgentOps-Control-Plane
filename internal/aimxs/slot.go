package aimxs

import "context"

// ProviderKind maps AIMXS external modules to the public provider contracts.
type ProviderKind string

const (
	ProviderKindPolicy   ProviderKind = "PolicyProvider"
	ProviderKindEvidence ProviderKind = "EvidenceProvider"
	ProviderKindProfile  ProviderKind = "ProfileResolver"
)

// EndpointAuthMode mirrors contract auth modes for external provider endpoints.
type EndpointAuthMode string

const (
	EndpointAuthNone                  EndpointAuthMode = "None"
	EndpointAuthBearerTokenSecret     EndpointAuthMode = "BearerTokenSecret"
	EndpointAuthMTLS                  EndpointAuthMode = "MTLS"
	EndpointAuthMTLSAndBearerTokenRef EndpointAuthMode = "MTLSAndBearerTokenSecret"
)

// ExternalProviderEndpoint declares how the control plane should call AIMXS over HTTPS.
type ExternalProviderEndpoint struct {
	URL                  string
	AuthMode             EndpointAuthMode
	ContractVersion      string
	BearerTokenSecretRef string
	ClientTLSSecretRef   string
	CASecretRef          string
}

// Registration is the adapter-boundary object used by an external AIMXS slot implementation.
type Registration struct {
	ProviderID   string
	ProviderKind ProviderKind
	Priority     int32
	Capabilities []string
	Endpoint     ExternalProviderEndpoint
	Metadata     map[string]string
}

// SlotResolver resolves which external AIMXS provider registration should serve a capability.
// Implementations live outside this OSS repository.
type SlotResolver interface {
	Resolve(ctx context.Context, capability string, tenantID string, projectID string) (Registration, error)
}

// SlotRegistry abstracts register/deregister operations for external AIMXS modules.
// An AIMXS private module can own this implementation while OSS code depends only on this interface.
type SlotRegistry interface {
	Register(ctx context.Context, registration Registration) error
	Deregister(ctx context.Context, providerID string) error
}
