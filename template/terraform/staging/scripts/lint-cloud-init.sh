#!/usr/bin/env bash
# lint-cloud-init.sh — extract the `runcmd:` block from cloud-init.yaml
# and pipe it to shellcheck as a synthetic bash script.
#
# Shellcheck doesn't parse YAML; running it directly on cloud-init.yaml
# produces nonsense errors on YAML keys. This wrapper does the right
# thing: parses the YAML with python+pyyaml, emits each runcmd entry as
# a separate bash line, prepends a shebang + `set -euo pipefail`, and
# pipes the result through the linter as bash.
#
# Usage:
#   ./lint-cloud-init.sh [path/to/cloud-init.yaml]
#
# Default path: the shared module's cloud-init template
# (terraform/modules/${PROJECT_NAME}-env/cloud-init.yaml.tftpl).
#
# Exits with shellcheck's exit code: 0 = clean, non-zero = findings.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_yaml="${script_dir}/../../modules/${PROJECT_NAME}-env/cloud-init.yaml.tftpl"
yaml_file="${1:-${default_yaml}}"

if [[ ! -f "${yaml_file}" ]]; then
  echo "lint-cloud-init.sh: yaml file not found: ${yaml_file}" >&2
  exit 2
fi

extracted="$(python3 - "${yaml_file}" <<'PY'
import sys
import yaml

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    doc = yaml.safe_load(f)

cmds = (doc or {}).get('runcmd', []) or []

print('#!/usr/bin/env bash')
print('set -euo pipefail')
for c in cmds:
    if isinstance(c, list):
        # exec-form: each element is an argv arg; join with spaces for
        # shellcheck's benefit (it cares about shell syntax, not argv).
        print(' '.join(str(x) for x in c))
    else:
        print(str(c))
PY
)"

# Feed the synthetic script to shellcheck. -x lets `source` resolve;
# -s bash forces the bash dialect (cloud-init's default `sh` is dash on
# Ubuntu but we wrap every redirect in `bash -c '...'` so the bash
# dialect is the right target).
printf '%s\n' "${extracted}" | shellcheck -x -s bash -
