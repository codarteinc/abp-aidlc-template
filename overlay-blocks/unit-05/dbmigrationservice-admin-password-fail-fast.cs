// Audit finding F-007 + F-002 — refuse to seed admin with unset password
// or a known-leaked placeholder. The hashlist holds SHA-256(UTF-8) hex
// digests so the leaked plaintexts are never present in source. Add new
// entries by SHA-256-hashing the leaked plaintext and pasting the
// lowercase hex digest below.
//
// The three pre-shipped hashes cover the legacy ABP-template default
// admin passwords. Operators with their own known-bad list extend the
// array in-place — the lookup is constant-cost regardless of length.
var __adminPassword = _configuration["App:AdminPassword"];

if (string.IsNullOrWhiteSpace(__adminPassword))
{
    throw new System.InvalidOperationException(
        "Missing required configuration 'App:AdminPassword'. " +
        "Set a strong admin password before running migrations / seeding. " +
        "For local dev, copy BOTH secrets templates and set a unique value in each: " +
        "src/${PROJECT_NAME}.DbMigrator/appsettings.secrets.json.template -> " +
        "appsettings.secrets.json (the file this process loads) AND " +
        "src/${PROJECT_NAME}.HttpApi.Host/appsettings.secrets.json.template -> " +
        "appsettings.secrets.json (loaded by the API host). " +
        "Both templates ship REPLACE_ME — override locally.");
}

var __leakedAdminPasswordHashes = new[]
{
    "60ee4b4d6802ab8c4b33b164be9a3319f08941908bfaf85c7c1ad7aedc03b822",
    "49ca938a16af564567b77f93c6990a5d6094f15be9977f2a80dc64d965e3ad25",
    "3eb3fe66b31e3b4d10fa70b5cad49c7112294af6ae4e476a1c405155d45aa121",
};

static string __computeAdminPasswordHash(string value)
{
    var bytes = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value));
    var sb = new System.Text.StringBuilder(bytes.Length * 2);
    foreach (var b in bytes)
    {
        sb.Append(b.ToString("x2"));
    }
    return sb.ToString();
}

var __candidateHash = __computeAdminPasswordHash(__adminPassword);
if (System.Array.Exists(__leakedAdminPasswordHashes, h => string.Equals(__candidateHash, h, System.StringComparison.OrdinalIgnoreCase)))
{
    throw new System.InvalidOperationException(
        "Refusing to seed with a known-leaked admin password (value " +
        "matches a documented dev placeholder). Set a strong, unique " +
        "password via App:AdminPassword in appsettings.secrets.json " +
        "or the APP__AdminPassword env var.");
}
