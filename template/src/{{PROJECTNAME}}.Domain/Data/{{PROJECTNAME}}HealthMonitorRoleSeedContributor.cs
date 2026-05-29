using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Volo.Abp.Data;
using Volo.Abp.DependencyInjection;
using Volo.Abp.Guids;
using Volo.Abp.Identity;
using Volo.Abp.MultiTenancy;

namespace ${PROJECT_NAME}.Data;

/// <summary>
/// Audit finding F-021 — seeds the <c>health-monitor</c> role under
/// the host tenant so the <c>HealthChecksPolicy</c> in
/// <c>${PROJECT_NAME}HttpApiHostModule</c> has a real role to bind. Without
/// this seeder, the policy registration is a dead-end and
/// <c>/health-ready</c> + <c>/metrics</c> return 401 forever even
/// for an operator with a properly-scoped service account.
///
/// <para>
/// The role is intentionally seeded with NO users — the binding to a
/// k8s service account or operator user is out-of-scope for the audit
/// (operator concern). The seeder is idempotent.
/// </para>
///
/// <para>
/// <c>IsStatic = true</c> matches how ABP seeds the <c>admin</c> role —
/// signals to the UI/audit that the role is system-managed and should
/// not be edited via the role-management UI.
/// <c>IsPublic = false</c> — not user-assignable from the public
/// registration flow.
/// </para>
/// </summary>
public class ${PROJECT_NAME}HealthMonitorRoleSeedContributor : IDataSeedContributor, ITransientDependency
{
    public const string RoleName = "health-monitor";

    public ILogger<${PROJECT_NAME}HealthMonitorRoleSeedContributor> Logger { get; set; }

    private readonly IIdentityRoleRepository _roleRepository;
    private readonly IGuidGenerator _guidGenerator;
    private readonly ICurrentTenant _currentTenant;

    public ${PROJECT_NAME}HealthMonitorRoleSeedContributor(
        IIdentityRoleRepository roleRepository,
        IGuidGenerator guidGenerator,
        ICurrentTenant currentTenant)
    {
        _roleRepository = roleRepository;
        _guidGenerator = guidGenerator;
        _currentTenant = currentTenant;

        Logger = NullLogger<${PROJECT_NAME}HealthMonitorRoleSeedContributor>.Instance;
    }

    public async Task SeedAsync(DataSeedContext context)
    {
        // F-016 partner — `_currentTenant.Change` is a no-op while
        // multi-tenancy is disabled, but kept for future-proofing.
        using var _ = _currentTenant.Change(context?.TenantId);

        var existing = await _roleRepository.FindByNormalizedNameAsync(
            RoleName.ToUpperInvariant(),
            cancellationToken: CancellationToken.None);
        if (existing != null)
        {
            Logger.LogDebug(
                "{Role} role already exists; skipping ${PROJECT_NAME}HealthMonitorRoleSeedContributor",
                RoleName);
            return;
        }

        var role = new IdentityRole(
            _guidGenerator.Create(),
            RoleName,
            tenantId: context?.TenantId)
        {
            IsStatic = true,
            IsPublic = false,
        };
        await _roleRepository.InsertAsync(role, autoSave: true);

        Logger.LogInformation(
            "Created {Role} role for F-021 health-check policy.",
            RoleName);
    }
}
