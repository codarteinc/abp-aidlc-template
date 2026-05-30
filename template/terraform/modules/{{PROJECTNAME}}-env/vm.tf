# SSH keys — one Hetzner-side `hcloud_ssh_key` per operator pubkey.
# Registering the key here (rather than only in cloud-init's `users:` block)
# lets Hetzner inject the keys at server-create time, BEFORE cloud-init
# runs. If cloud-init hangs / fails, the operator can still SSH in and
# inspect — the keys exist before the bootstrap script.
resource "hcloud_ssh_key" "operators" {
  for_each = var.operator_ssh_pubkeys

  name       = "${PROJECT_NAME_LOWER}-${var.env_name}-operator-${each.key}"
  public_key = each.value
}

# Primary IPv4 — separate resource so the IP survives `terraform destroy`
# of the server. `auto_delete = false` is critical: even if Hetzner detaches
# the IP during a server replacement, the IP itself stays in the project so
# DNS records (and operator muscle memory) don't churn.
#
# IPv6 is intentionally NOT a separate hcloud_primary_ip resource: Hetzner
# allocates a /64 to every server for free, and `hcloud_server` exposes
# the assigned `ipv6_address` as an attribute (consumed by outputs.tf +
# dns.tf). Allocating a separate primary IPv6 would let it survive a
# server replacement too, but at the cost of an extra €0.50/mo — staging-
# tier envs don't need that.
resource "hcloud_primary_ip" "app" {
  name        = "${PROJECT_NAME_LOWER}-${var.env_name}-ipv4"
  type        = "ipv4"
  location    = var.server_location
  auto_delete = false
}

# Server — the actual VM. `user_data` is rendered in main.tf.
#
# `firewall_ids` on `hcloud_server` is the single-attach form. We use the
# separate `hcloud_firewall_attachment` resource (in firewall.tf) for a
# cleaner lifecycle (firewall can change without a server replacement).
#
# IPv6 is enabled (free /64 from Hetzner); we don't pin a specific IPv6
# resource because Hetzner allocates per-server and the address survives
# server-type changes.
resource "hcloud_server" "app" {
  name        = "${PROJECT_NAME_LOWER}-${var.env_name}-app"
  server_type = var.server_type
  image       = var.server_image
  location    = var.server_location

  ssh_keys = [for k in hcloud_ssh_key.operators : k.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.app.id
    ipv6_enabled = true
  }

  user_data = local.cloud_init

  # We do NOT use Hetzner-managed backups (20% surcharge). Snapshots +
  # pg_dump-to-Object-Storage are the backup strategy (deferred to a
  # later intent).
  backups = false

  labels = {
    role    = "app"
    env     = var.env_name
    managed = "terraform"
  }
}

# Reverse DNS for the primary IPv4 (cosmetic — cleans up Let's Encrypt /
# log lines / SMTP traces). Points at the SPA hostname; not used for any
# routing decision.
resource "hcloud_rdns" "app" {
  server_id  = hcloud_server.app.id
  ip_address = hcloud_primary_ip.app.ip_address
  dns_ptr    = local.app_hostname
}
