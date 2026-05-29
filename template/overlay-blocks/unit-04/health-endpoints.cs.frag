        // Audit finding F-021 — health checks + auth policy.
        // Wires:
        //   - `self` check tagged "live"  -> served by /health-live (anonymous)
        //   - `${PROJECT_NAME}DatabaseCheck` tagged "ready" -> served by
        //     /health-ready (auth-gated by HealthChecksPolicy)
        //   - HealthChecksPolicy requires authenticated user with role
        //     `admin` OR `${PROJECT_NAME}HealthMonitorRoleSeedContributor.RoleName`
        //     (= "health-monitor", seeded by the Domain-layer contributor).
        //
        // Operators with network-level controls (k8s NetworkPolicy, LB IP
        // allowlist) can opt the /metrics endpoint OUT of the auth gate via
        // App:Metrics:Auth=false in appsettings.json.
        context.Services.Add${PROJECT_NAME}HealthChecks();

        context.Services.AddAuthorization(${PROJECT_NAME_LOWER}HealthOpts =>
        {
            ${PROJECT_NAME_LOWER}HealthOpts.AddPolicy(
                ${PROJECT_NAME}.HealthChecks.HealthChecksBuilderExtensions.HealthChecksPolicyName,
                policy => policy
                    .RequireAuthenticatedUser()
                    .RequireRole(
                        "admin",
                        ${PROJECT_NAME}.Data.${PROJECT_NAME}HealthMonitorRoleSeedContributor.RoleName));
        });

        // Audit finding F-039 — Prometheus scrape endpoint at /metrics.
        // Auth-gated by HealthChecksPolicy unless App:Metrics:Auth=false
        // (operator override for network-level-controlled environments).
        var ${PROJECT_NAME_LOWER}MetricsConfiguration = context.Services.GetConfiguration();
        var ${PROJECT_NAME_LOWER}MetricsAuthEnabled =
            ${PROJECT_NAME_LOWER}MetricsConfiguration.GetValue<bool?>("App:Metrics:Auth") ?? true;
        context.Services.Configure<Volo.Abp.AspNetCore.Mvc.AbpEndpointRouterOptions>(options =>
        {
            options.EndpointConfigureActions.Add(endpointContext =>
            {
                var endpoint = endpointContext.Endpoints.MapPrometheusScrapingEndpoint();
                if (${PROJECT_NAME_LOWER}MetricsAuthEnabled)
                {
                    endpoint.RequireAuthorization(
                        ${PROJECT_NAME}.HealthChecks.HealthChecksBuilderExtensions.HealthChecksPolicyName);
                }
            });
        });
