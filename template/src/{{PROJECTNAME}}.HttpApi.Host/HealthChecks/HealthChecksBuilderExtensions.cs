using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Volo.Abp.AspNetCore.Mvc;

namespace ${PROJECT_NAME}.HealthChecks;

/// <summary>
/// Audit finding F-021 — readiness/liveness split with an auth gate on
/// readiness. The previous shape exposed <c>/health-status</c>,
/// <c>/health-ui</c>, <c>/health-api</c> as anonymous endpoints,
/// leaking DB connectivity, request counts, and framework fingerprint
/// (HealthChecks.UI).
///
/// <para>
/// New shape:
/// </para>
/// <list type="bullet">
///   <item><description>
///     <c>/health-live</c> — anonymous, no DB, no info. K8s liveness
///     probes consume this. Body is empty; status is 200 if the
///     process can run a request through routing.
///   </description></item>
///   <item><description>
///     <c>/health-ready</c> — DB check, auth-gated by
///     <see cref="HealthChecksPolicyName"/>. K8s readiness probes
///     authenticate via a service-account token tied to the
///     <c>health-monitor</c> role (seeded by
///     <c>${PROJECT_NAME}HealthMonitorRoleSeedContributor</c>).
///   </description></item>
///   <item><description>
///     <c>/health-status</c>, <c>/health-ui</c>, <c>/health-api</c>
///     are REMOVED — they leaked framework fingerprint and DB state.
///   </description></item>
/// </list>
/// </summary>
public static class HealthChecksBuilderExtensions
{
    public const string HealthChecksPolicyName = "HealthChecksPolicy";

    public static void Add${PROJECT_NAME}HealthChecks(this IServiceCollection services)
    {
        services.AddHealthChecks()
            .AddCheck(
                "self",
                () => HealthCheckResult.Healthy(),
                tags: new[] { "live" })
            .AddCheck<${PROJECT_NAME}DatabaseCheck>(
                "database",
                tags: new[] { "ready" });

        services.ConfigureLiveEndpoint();
        services.ConfigureReadyEndpoint();
    }

    /// <summary>
    /// <c>/health-live</c> — anonymous, no DB, no info. K8s liveness
    /// probes consume this. Body is empty; status code is 200 if the
    /// process can run a request through routing.
    /// </summary>
    private static void ConfigureLiveEndpoint(this IServiceCollection services)
    {
        services.Configure<AbpEndpointRouterOptions>(options =>
        {
            options.EndpointConfigureActions.Add(endpointContext =>
            {
                endpointContext.Endpoints.MapHealthChecks(
                    "/health-live",
                    new HealthCheckOptions
                    {
                        Predicate = check => check.Tags.Contains("live"),
                        AllowCachingResponses = false,
                        ResponseWriter = (ctx, report) =>
                        {
                            ctx.Response.StatusCode = report.Status == HealthStatus.Healthy
                                ? StatusCodes.Status200OK
                                : StatusCodes.Status503ServiceUnavailable;
                            return Task.CompletedTask;
                        },
                    });
            });
        });
    }

    /// <summary>
    /// <c>/health-ready</c> — DB check, auth-gated by
    /// <see cref="HealthChecksPolicyName"/>. K8s readiness probes
    /// authenticate via a service-account token tied to the
    /// <c>health-monitor</c> role (seeded by
    /// <c>${PROJECT_NAME}HealthMonitorRoleSeedContributor</c>).
    /// </summary>
    private static void ConfigureReadyEndpoint(this IServiceCollection services)
    {
        services.Configure<AbpEndpointRouterOptions>(options =>
        {
            options.EndpointConfigureActions.Add(endpointContext =>
            {
                endpointContext.Endpoints
                    .MapHealthChecks(
                        "/health-ready",
                        new HealthCheckOptions
                        {
                            Predicate = check => check.Tags.Contains("ready"),
                            AllowCachingResponses = false,
                            ResponseWriter = (ctx, report) =>
                            {
                                ctx.Response.StatusCode = report.Status == HealthStatus.Healthy
                                    ? StatusCodes.Status200OK
                                    : StatusCodes.Status503ServiceUnavailable;
                                ctx.Response.ContentType = "text/plain";
                                return ctx.Response.WriteAsync(
                                    report.Status == HealthStatus.Healthy
                                        ? "healthy"
                                        : "unhealthy");
                            },
                        })
                    .RequireAuthorization(HealthChecksPolicyName);
            });
        });
    }
}
