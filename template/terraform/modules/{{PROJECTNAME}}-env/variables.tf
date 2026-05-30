# Inputs for the reusable ${PROJECT_NAME_LOWER}-env module.
#
# The variable surface fully encapsulates today's `terraform/<env>/`
# env-varying knobs. Six required inputs (no defaults) + six optional inputs
# (defaults match today's staging values). See README.md for the consumer
# contract.

# ----------------------------------------------------------------------------
# Required inputs
# ----------------------------------------------------------------------------

variable "env_name" {
  description = "Short environment slug (e.g., \"staging\", \"staging2\"). Used as the Hetzner resource-name suffix (`${PROJECT_NAME_LOWER}-<env_name>-app`, `${PROJECT_NAME_LOWER}-<env_name>-firewall`, etc.) and in the `env` label on every managed resource. Lowercase letters, digits, and hyphens only — no spaces."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.env_name))
    error_message = "env_name must be lowercase alphanumeric with hyphens (e.g., 'staging', 'staging2')."
  }
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read+Write scope, single project). Pass via TF_VAR_hcloud_token env var in the consuming root; never commit."
  type        = string
  sensitive   = true
}

variable "operator_ssh_pubkeys" {
  description = "Map of operator SSH public keys keyed by a stable short name (e.g., { \"alice-laptop\" = \"ssh-ed25519 AAAA... alice@laptop\" }). Each entry is registered as a `hcloud_ssh_key` and injected into the server at create time. The map key is used to name the `hcloud_ssh_key` resource (`${PROJECT_NAME_LOWER}-<env_name>-operator-<key>`)."
  type        = map(string)

  validation {
    condition     = length(var.operator_ssh_pubkeys) > 0
    error_message = "operator_ssh_pubkeys must contain at least one key — Hetzner injects these at server-create time, before cloud-init runs."
  }

  validation {
    condition     = alltrue([for k in values(var.operator_ssh_pubkeys) : can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) AAAA", k))])
    error_message = "Every value in operator_ssh_pubkeys must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-nistp256 followed by 'AAAA...'."
  }
}

variable "ssh_allowed_cidrs" {
  description = "List of CIDR blocks allowed to SSH (port 22) into the VM. Example: [\"203.0.113.7/32\", \"198.51.100.42/32\"]. ICMP is gated to the same list so external scanners get silence."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must include at least one operator CIDR — an empty list would lock everyone out of the VM."
  }

  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry in ssh_allowed_cidrs must be a valid CIDR (e.g., 203.0.113.7/32)."
  }
}

variable "app_hostname" {
  description = "Fully-qualified hostname for the SPA edge (e.g., \"app.staging.example.com\"). When empty and dns_provider=\"none\", the module falls back to an sslip.io hostname derived from the primary IPv4."
  type        = string
}

variable "api_hostname" {
  description = "Fully-qualified hostname for the API edge (e.g., \"api.staging.example.com\"). When empty and dns_provider=\"none\", the module falls back to an sslip.io hostname derived from the primary IPv4."
  type        = string
}

# ----------------------------------------------------------------------------
# Optional inputs (defaults match the scaffold-config-supplied values)
# ----------------------------------------------------------------------------

variable "server_type" {
  description = "Hetzner Cloud server type. cx23 is the smallest current x86 box; bump to cx33 once the stack starts swapping under real load. (Old cx22/cx32 names were retired by Hetzner in 2026.)"
  type        = string
  default     = "${HETZNER_SERVER_TYPE}"
}

variable "server_location" {
  description = "Hetzner Cloud location (datacenter park). nbg1 = Nuremberg, fsn1 = Falkenstein, hel1 = Helsinki."
  type        = string
  default     = "${HETZNER_LOCATION}"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1"], var.server_location)
    error_message = "server_location must be one of: nbg1, fsn1, hel1."
  }
}

variable "server_image" {
  description = "Hetzner Cloud image. ubuntu-24.04 (Noble) is the only supported value for this module — cloud-init.yaml.tftpl pins the Docker apt repo to `noble`."
  type        = string
  default     = "ubuntu-24.04"
}

variable "dns_provider" {
  description = "Which DNS provider Terraform should manage. \"none\" (default) → operator manages DNS out-of-band; the module emits sslip.io fallback hostnames. \"cloudflare\" → the four cloudflare_dns_record resources are instantiated and require `cloudflare_api_token` + `cloudflare_zone_id` + `app_hostname` + `api_hostname` to be set."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "cloudflare"], var.dns_provider)
    error_message = "dns_provider must be 'none' or 'cloudflare'."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID (NOT the domain name) where the env records will be created. Required when `dns_provider = \"cloudflare\"`."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Edit on the configured zone. Required when `dns_provider = \"cloudflare\"`. Pass via TF_VAR_cloudflare_api_token env var in the consuming root; never commit."
  type        = string
  sensitive   = true
  default     = ""
}
