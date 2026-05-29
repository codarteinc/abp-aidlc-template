using System.Threading.Tasks;
using Volo.Abp.Data;
using Volo.Abp.DependencyInjection;

namespace ${PROJECT_NAME};

// Empty test-only data seed contributor. ABP picks this up via
// ITransientDependency conventional registration and runs it during
// IDataSeeder.SeedAsync(), which ${PROJECT_NAME}TestBaseModule invokes
// from OnApplicationInitialization.
//
// Add your test-only seed data here (admin extra roles, sample
// entities, etc.). Keep PRODUCTION seed data in
// src/${PROJECT_NAME}.Domain/Data/*SeedContributor.cs instead.
public class ${PROJECT_NAME}TestDataSeedContributor : IDataSeedContributor, ITransientDependency
{
    public Task SeedAsync(DataSeedContext context)
    {
        return Task.CompletedTask;
    }
}
