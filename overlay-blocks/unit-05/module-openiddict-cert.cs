// Audit finding F-007 — OpenIddict cert switch. Development: lets ABP's
// default AddDevelopmentEncryptionAndSigningCertificate wire an in-memory
// cert (no PFX file required — `dotnet dev-certs https` already on
// machine). Non-Development (Staging/Production): requires an
// operator-supplied PFX at AuthServer:CertificatePath (defaults to
// ./openiddict.pfx if unset) with passphrase at
// AuthServer:CertificatePassPhrase. Generate the dev PFX with:
//   bash etc/generate-dev-openiddict-cert.sh
//
// WITHOUT this switch the scaffolded app loads ABP's dev cert in
// Production — equivalent to shipping a default admin password.
var __hostingEnvironment = context.Services.GetHostingEnvironment();
var __configuration = context.Services.GetConfiguration();
if (!__hostingEnvironment.IsDevelopment())
{
    PreConfigure<Volo.Abp.OpenIddict.AbpOpenIddictAspNetCoreOptions>(options =>
    {
        options.AddDevelopmentEncryptionAndSigningCertificate = false;
    });

    var __certPath = __configuration["AuthServer:CertificatePath"] ?? "openiddict.pfx";
    var __certPassphrase = __configuration["AuthServer:CertificatePassPhrase"]
        ?? throw new System.InvalidOperationException(
            "AuthServer:CertificatePassPhrase is required in non-Development environments. " +
            "Set it in appsettings.secrets.json or via the env var " +
            "AuthServer__CertificatePassPhrase. The matching PFX file path is " +
            "AuthServer:CertificatePath (defaults to ./openiddict.pfx).");
    var __selfUrl = __configuration["App:SelfUrl"]
        ?? throw new System.InvalidOperationException(
            "App:SelfUrl is required in non-Development environments (used as the OpenIddict issuer).");

    PreConfigure<OpenIddict.Server.OpenIddictServerBuilder>(serverBuilder =>
    {
        serverBuilder.AddProductionEncryptionAndSigningCertificate(__certPath, __certPassphrase);
        serverBuilder.SetIssuer(new System.Uri(__selfUrl));
    });
}
