// Audit finding F-010 — per-developer local override (gitignored). Loaded
// AFTER appsettings.json + appsettings.{Environment}.json so its keys win
// for the current developer's machine without ever touching tracked files.
// Mirrors the Angular-side `environment.local.ts` for symmetric URL
// overrides (App:SelfUrl, App:AngularUrl, App:CorsOrigins,
// App:RedirectAllowedUrls, AuthServer:Authority). Keep secrets OUT of this
// file — secrets still live in `appsettings.secrets.json` and load via
// the secrets-json-loader block in ${PROJECT_NAME}HttpApiHostModule.cs.
// Gated on IsDevelopment so a stray file in a non-dev environment cannot
// silently override production settings.
if (builder.Environment.IsDevelopment())
{
    builder.Configuration.AddJsonFile(
        "appsettings.Development.local.json",
        optional: true,
        reloadOnChange: true);
}
