        // Audit finding F-039 — OpenTelemetry metrics + traces. Registers
        // AspNetCore + HttpClient + EF Core instrumentation, the wildcard
        // `${PROJECT_NAME}.*` meter subscription (picks up every custom meter
        // declared with `new Meter("${PROJECT_NAME}.<Feature>")`), the
        // Prometheus exporter (for the /metrics scrape endpoint registered
        // in the health-endpoints block below), and the OTLP exporter
        // (honors $OTEL_EXPORTER_OTLP_ENDPOINT — no-op when unset).
        var ${PROJECT_NAME_LOWER}OtelServiceVersion = typeof(${PROJECT_NAME}HttpApiHostModule)
            .Assembly.GetName().Version?.ToString() ?? "0.0.0";

        context.Services.AddOpenTelemetry()
            .ConfigureResource(b => b.AddService(
                serviceName: "${PROJECT_NAME_LOWER}-api",
                serviceVersion: ${PROJECT_NAME_LOWER}OtelServiceVersion))
            .WithMetrics(b => b
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                // F-039 — wildcard subscription picks up every
                // `${PROJECT_NAME}.<Feature>` Meter (and any future feature).
                // Convention: every custom Meter uses the dot-prefixed
                // `${PROJECT_NAME}.` namespace; instrument names use
                // snake_case + unit suffix. See docs/observability.md.
                .AddMeter("${PROJECT_NAME}.*")
                .AddPrometheusExporter())
            .WithTracing(b => b
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                .AddEntityFrameworkCoreInstrumentation()
                // F-039 — OTLP exporter honors OTEL_EXPORTER_OTLP_ENDPOINT
                // env var. When unset, the SDK silently no-ops (the
                // documented behavior). Operators set
                // OTEL_EXPORTER_OTLP_ENDPOINT=https://collector:4317 (or
                // /v1/traces for HTTP) to enable export.
                .AddOtlpExporter());
