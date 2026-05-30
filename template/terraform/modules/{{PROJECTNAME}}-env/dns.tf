# Cloudflare DNS records — only instantiated when `dns_provider == "cloudflare"`.
#
# The v5 Cloudflare provider renamed `cloudflare_record` →
# `cloudflare_dns_record`. v5 attribute schema: `zone_id`, `name`, `type`,
# `content`, `ttl`, `proxied`. If a future v5.x release ships further
# attribute renames, `terraform validate` catches it before any apply.
#
# TTL is 300 (5 min) for staging-tier envs so DNS swings during early
# iteration land quickly. Operator bumps to 3600 in the runbook once the
# env is stable. `proxied = false` because we want Caddy on the VM to
# handle ACME (the Cloudflare proxy hides the origin's TLS certificate flow).

resource "cloudflare_dns_record" "app_a" {
  count = var.dns_provider == "cloudflare" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.app_hostname
  content = hcloud_primary_ip.app.ip_address
  type    = "A"
  ttl     = 300
  proxied = false

  # Cross-variable conditional validation. Terraform `validation{}` blocks
  # on a single variable cannot reference other variables, so the
  # required-when-cloudflare check lives here. Asserting on ONE record
  # (rather than all four) is sufficient because every cloudflare_dns_record
  # in this file is gated by the same `count` expression.
  lifecycle {
    precondition {
      condition = var.dns_provider != "cloudflare" || (
        length(trimspace(var.cloudflare_zone_id)) > 0 &&
        length(trimspace(var.cloudflare_api_token)) > 0 &&
        length(trimspace(var.app_hostname)) > 0 &&
        length(trimspace(var.api_hostname)) > 0
      )
      error_message = "When dns_provider = \"cloudflare\", you must set cloudflare_zone_id, cloudflare_api_token, app_hostname, and api_hostname (all currently optional and defaulted to empty strings)."
    }
  }
}

resource "cloudflare_dns_record" "app_aaaa" {
  count = var.dns_provider == "cloudflare" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.app_hostname
  content = hcloud_server.app.ipv6_address
  type    = "AAAA"
  ttl     = 300
  proxied = false
}

resource "cloudflare_dns_record" "api_a" {
  count = var.dns_provider == "cloudflare" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.api_hostname
  content = hcloud_primary_ip.app.ip_address
  type    = "A"
  ttl     = 300
  proxied = false
}

resource "cloudflare_dns_record" "api_aaaa" {
  count = var.dns_provider == "cloudflare" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.api_hostname
  content = hcloud_server.app.ipv6_address
  type    = "AAAA"
  ttl     = 300
  proxied = false
}
