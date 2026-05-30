# Provider + Terraform version constraints for the reusable ${PROJECT_NAME_LOWER}-env module.
#
# The module does NOT declare a `cloud {}` backend — the consuming root module
# (`terraform/<env>/`) configures backend and provider credentials. This is the
# standard Terraform module convention and lets each env-root point at its own
# HCP workspace + Hetzner project + Cloudflare token.

terraform {
  required_version = "~> 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.63"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
