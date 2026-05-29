using Volo.Abp.Identity;

namespace ${PROJECT_NAME};

// Project-wide constants. Custom EF Core entities use this prefix on
// table names; the default value `App` is a convention shared with
// LinkHub and is safe to keep for new projects. Adjust only if you
// need to disambiguate tables in a shared schema.
public static class ${PROJECT_NAME}Consts
{
    public const string DbTablePrefix = "App";
    public const string? DbSchema = null;
    public const string AdminEmailDefaultValue = IdentityDataSeedContributor.AdminEmailDefaultValue;
}
