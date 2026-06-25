package main

import (
	"log"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/confmap"
	envprovider "go.opentelemetry.io/collector/confmap/provider/envprovider"
	fileprovider "go.opentelemetry.io/collector/confmap/provider/fileprovider"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/extension"
	"go.opentelemetry.io/collector/otelcol"
	"go.opentelemetry.io/collector/receiver"
	"go.opentelemetry.io/collector/service/telemetry/otelconftelemetry"

	debugexporter "go.opentelemetry.io/collector/exporter/debugexporter"
	otlphttpexporter "go.opentelemetry.io/collector/exporter/otlphttpexporter"
	otlpreceiver "go.opentelemetry.io/collector/receiver/otlpreceiver"

	awssecretsmanagerprovider "github.com/open-telemetry/opentelemetry-collector-contrib/extension/awssecretsmanagerprovider"
	basicauthextension "github.com/open-telemetry/opentelemetry-collector-contrib/extension/basicauthextension"
)

func main() {
	cmd := otelcol.NewCommand(otelcol.CollectorSettings{
		BuildInfo: component.BuildInfo{
			Command:     "otel-integration-test",
			Description: "Integration test collector",
			Version:     "dev",
		},
		Factories: components,
		ConfigProviderSettings: otelcol.ConfigProviderSettings{
			ResolverSettings: confmap.ResolverSettings{
				ProviderFactories: []confmap.ProviderFactory{
					fileprovider.NewFactory(),
					envprovider.NewFactory(),
				},
				DefaultScheme: "env",
			},
		},
	})

	if err := cmd.Execute(); err != nil {
		log.Fatal(err)
	}
}

func components() (otelcol.Factories, error) {
	var err error
	factories := otelcol.Factories{}

	factories.Telemetry = otelconftelemetry.NewFactory()

	factories.Extensions, err = otelcol.MakeFactoryMap[extension.Factory](
		basicauthextension.NewFactory(),
		awssecretsmanagerprovider.NewFactory(),
	)
	if err != nil {
		return otelcol.Factories{}, err
	}

	factories.Receivers, err = otelcol.MakeFactoryMap[receiver.Factory](
		otlpreceiver.NewFactory(),
	)
	if err != nil {
		return otelcol.Factories{}, err
	}

	factories.Exporters, err = otelcol.MakeFactoryMap[exporter.Factory](
		debugexporter.NewFactory(),
		otlphttpexporter.NewFactory(),
	)
	if err != nil {
		return otelcol.Factories{}, err
	}

	return factories, nil
}
