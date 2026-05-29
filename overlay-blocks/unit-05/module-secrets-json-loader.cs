// dockerize-app config-load-order fix. ABP's `.AddAppSettingsSecretsJson()`
// runs as a ConfigureAppConfiguration callback that appends
// `appsettings.secrets.json` to the source list AFTER env vars + CLI,
// which makes secrets override env vars (the opposite of operator
// expectation). The hook below loads secrets DIRECTLY here and re-appends
// env vars + CLI so final precedence is:
//   appsettings.json -> appsettings.{env}.json -> appsettings.{env}.local.json
//   -> appsettings.secrets.json -> env vars -> command line.
//
// In ConfigureServices the only thing we can do is ensure the secrets
// file is part of the rebuilt configuration. The full re-ordering happens
// at Program.cs builder time (see the `cookie-antiforgery-cors` block).
// This block exists so a future operator who removes the Program.cs
// loader still has the secrets file loaded by the module — defense in
// depth.
context.Services.AddSingleton<Microsoft.Extensions.Configuration.IConfiguration>(provider =>
{
    var existing = context.Services.GetConfiguration();
    return new Microsoft.Extensions.Configuration.ConfigurationBuilder()
        .AddConfiguration(existing)
        .AddJsonFile("appsettings.secrets.json", optional: true, reloadOnChange: true)
        .Build();
});
