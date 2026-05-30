# DO NOT USE WITH `terraform apply` — validate-only scratch values.
#
# Purpose: drives a second `terraform validate` run with
# `dns_provider = "cloudflare"` so we catch v5 provider-schema drift at
# lint time.
#
# The token below is FAKE. Real secrets go via the env vars
# TF_VAR_hcloud_token / TF_VAR_cloudflare_api_token at apply time. If
# you accidentally run `terraform apply -var-file=test/cloudflare.tfvars`
# Cloudflare's API will reject the fake token and Hetzner will reject
# the fake CIDR — harmless, but please don't.

hcloud_token         = "fake-for-validate-only"
cloudflare_api_token = "fake-for-validate-only"
cloudflare_zone_id   = "0123456789abcdef0123456789abcdef"
ssh_allowed_cidrs    = ["198.51.100.1/32"]
operator_ssh_pubkeys = { "validate-only" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY test@validate" }
dns_provider         = "cloudflare"
app_hostname         = "app.example.invalid"
api_hostname         = "api.example.invalid"
