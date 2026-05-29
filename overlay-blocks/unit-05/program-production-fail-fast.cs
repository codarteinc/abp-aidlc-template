// Audit finding F-006 — in Production, refuse to start if any required
// URL config key is missing. Catches misconfigurations early instead of
// returning 502 after the first browser request. Evaluated AFTER the
// secrets/env-vars/CLI sources have been merged in (see secrets-json-loader
// block in ${PROJECT_NAME}HttpApiHostModule.ConfigureServices).
if (builder.Environment.IsProduction())
{
    var __requiredKeys = new[]
    {
        "App:SelfUrl",
        "App:AngularUrl",
        "App:CorsOrigins",
        "App:RedirectAllowedUrls",
        "AuthServer:Authority",
    };
    var __missing = __requiredKeys
        .Where(k => string.IsNullOrWhiteSpace(builder.Configuration[k]))
        .ToArray();
    if (__missing.Length > 0)
    {
        var __joined = string.Join(", ", __missing);
        Serilog.Log.Fatal(
            "[${PROJECT_NAME}.Config] Missing required configuration keys in Production: {Keys}",
            __joined);
        throw new Microsoft.Extensions.Hosting.HostAbortedException(
            $"Missing required configuration keys in Production: {__joined}");
    }
}
