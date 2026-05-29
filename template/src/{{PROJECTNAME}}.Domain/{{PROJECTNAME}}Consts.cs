using Volo.Abp.Identity;

namespace ${PROJECT_NAME};

// Project-wide constants. Custom EF Core entities use this prefix on
// table names; the default value `App` is a convention shared with
// LinkHub and is safe to keep for new projects. Adjust only if you
// need to disambiguate tables in a shared schema.
//
// AdminEmailDefaultValue + AdminPasswordDefaultValue mirror the
// ABP-CLI-generated ${PROJECT_NAME}DbMigrationService references.
// The default password value matches ABP's own seed convention so the
// vanilla `dotnet build` of the scaffolded solution succeeds; operators
// MUST override via App:AdminPassword in appsettings.secrets.json before
// running the DbMigrator in any production-shaped environment (the
// admin-password fail-fast contributed by unit-05 enforces this).
public static class ${PROJECT_NAME}Consts
{
    public const string DbTablePrefix = "App";
    public const string? DbSchema = null;
    public const string AdminEmailDefaultValue = IdentityDataSeedContributor.AdminEmailDefaultValue;
    public const string AdminPasswordDefaultValue = IdentityDataSeedContributor.AdminPasswordDefaultValue;
}
