#!/usr/bin/env bash
# etc/generate-dev-openiddict-cert.sh
#
# Mint a local-dev OpenIddict signing/encryption certificate (openiddict.pfx)
# under src/${PROJECT_NAME}.HttpApi.Host/. Idempotent: re-running overwrites
# the existing dev cert; the .gitignore excludes it from the working tree.
#
# Requires:
#   - dotnet SDK (any 8+; this scaffold pins via global.json)
#   - OPENIDDICT_DEV_CERT_PASS env var (.env file ships a non-secret default)
#
# Usage:
#   OPENIDDICT_DEV_CERT_PASS=changeme bash etc/generate-dev-openiddict-cert.sh
#   or, more typically (the .env-loaded shell):
#     bash etc/generate-dev-openiddict-cert.sh
#
# Production: this script is NOT suitable for prod certs. See the operator
# runbook for the openssl recipe (longer validity + key-escrow procedure).

set -euo pipefail

if [[ -z "${OPENIDDICT_DEV_CERT_PASS:-}" ]]; then
    echo "ERROR: OPENIDDICT_DEV_CERT_PASS env var is required." >&2
    echo "       Set it in .env (the committed dev default is fine) or pass inline:" >&2
    echo "       OPENIDDICT_DEV_CERT_PASS=changeme bash etc/generate-dev-openiddict-cert.sh" >&2
    exit 1
fi

if ! command -v dotnet >/dev/null 2>&1; then
    echo "ERROR: dotnet SDK not found on PATH." >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_dir="${project_root}/src/${PROJECT_NAME}.HttpApi.Host"
if [[ ! -d "$host_dir" ]]; then
    echo "ERROR: host project dir not found at: $host_dir" >&2
    exit 1
fi

cert_path="${host_dir}/openiddict.pfx"
# Ensure we don't trip 'dev-certs clean' messes; just overwrite by removing first.
rm -f "$cert_path"

dotnet dev-certs https -v -ep "$cert_path" -p "$OPENIDDICT_DEV_CERT_PASS" --format pfx

# Reasonable POSIX perms — readable by the dotnet process, not world-readable.
chmod 600 "$cert_path"

echo "OK: dev OpenIddict cert written to ${cert_path}"
echo "     (gitignored via *.pfx in the root .gitignore)"
