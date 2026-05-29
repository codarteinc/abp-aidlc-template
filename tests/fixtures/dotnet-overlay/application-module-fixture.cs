using Volo.Abp.PermissionManagement;
using Volo.Abp.Modularity;
using Microsoft.Extensions.DependencyInjection;

namespace SmokeApp;

[DependsOn(
    typeof(SmokeAppDomainModule),
    typeof(SmokeAppApplicationContractsModule),
    typeof(AbpPermissionManagementApplicationModule)
    )]
public class SmokeAppApplicationModule : AbpModule
{
    public override void ConfigureServices(ServiceConfigurationContext context)
    {
    }
}
