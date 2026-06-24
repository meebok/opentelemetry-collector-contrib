// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package secretprovider // import "github.com/open-telemetry/opentelemetry-collector-contrib/extension/internal/secretprovider"

import "context"

// SecretProvider is an interface that extensions can implement to provide
// secret values to other extensions (e.g., basicauth). The provider is
// responsible for managing its own caching and refresh logic internally.
//
// This interface enables a cloud-agnostic pattern: separate provider extensions
// (e.g., AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, HashiCorp Vault)
// implement SecretProvider, and consumer extensions reference them by component ID
// via host.GetExtensions().
type SecretProvider interface {
	GetSecret(ctx context.Context) (string, error)
}
