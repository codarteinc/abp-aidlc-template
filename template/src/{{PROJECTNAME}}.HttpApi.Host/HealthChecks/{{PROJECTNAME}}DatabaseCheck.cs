using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using Volo.Abp.DependencyInjection;
using Volo.Abp.Identity;

namespace ${PROJECT_NAME}.HealthChecks;

/// <summary>
/// Audit finding F-038 — trivial DB connectivity probe used by
/// <c>/health-ready</c>. The failure path NEVER passes the original
/// exception to <see cref="HealthCheckResult.Unhealthy(string?)"/>; raw
/// <see cref="Exception"/> objects would propagate
/// <c>PostgresException</c> connection details (DB user, host, DB name)
/// to the response body, which — even with F-021's auth gate — must not
/// happen. The exception is logged in full to
/// <c>Logs/log-{date}.txt</c> via <see cref="ILogger{TCategoryName}"/>
/// (post-U2 destructuring policy scrubs PII from any
/// <c>IdentityUser</c> objects the exception might carry); only a
/// generic <c>"Database unavailable"</c> string reaches the wire.
/// </summary>
public class ${PROJECT_NAME}DatabaseCheck : IHealthCheck, ITransientDependency
{
    private readonly IIdentityRoleRepository _roleRepository;
    private readonly ILogger<${PROJECT_NAME}DatabaseCheck> _logger;

    public ${PROJECT_NAME}DatabaseCheck(
        IIdentityRoleRepository roleRepository,
        ILogger<${PROJECT_NAME}DatabaseCheck> logger)
    {
        _roleRepository = roleRepository;
        _logger = logger;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        try
        {
            // Trivial connectivity probe — pulls one role row to confirm
            // the DB is reachable and the schema is migrated. Same shape
            // as the pre-F-038 check; only the failure-path exception
            // handling and the success-path description string changed.
            await _roleRepository.GetListAsync(
                sorting: nameof(IdentityRole.Id),
                maxResultCount: 1,
                cancellationToken: cancellationToken);

            // Defense-in-depth: drop the "Could connect to database..."
            // description string from the previous shape. A future
            // reviewer who flips the response writer to expose the
            // description string should not see ANY framework detail
            // leak (even on the healthy path).
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            // Audit finding F-038 — log the full exception for operators
            // (destructuring policy in Program.cs scrubs PII from any
            // IdentityUser objects the exception might carry). Return
            // ONLY a generic message — the response body is
            // operator-visible via /health-ready (auth-gated by F-021).
            // Even with auth, the response must never carry
            // Npgsql / PostgresException connection details (db user,
            // host, db name); those land in Logs/log-{date}.txt where
            // the operator can grep them.
            _logger.LogError(ex, "Database health check failed");
            return HealthCheckResult.Unhealthy("Database unavailable");
        }
    }
}
