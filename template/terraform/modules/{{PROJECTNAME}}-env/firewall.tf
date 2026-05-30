# Firewall — three inbound rules + ICMP.
# Port 22 is gated to `var.ssh_allowed_cidrs`. Ports 80/443 are open to the
# world so Caddy can do ACME HTTP-01 challenges + serve traffic. ICMP is
# ALSO gated to `var.ssh_allowed_cidrs` so external scanners get silence
# (no ping reply, no fingerprint) — operators still get `ping` / MTR from
# their allowlisted IPs.
resource "hcloud_firewall" "app" {
  name = "${PROJECT_NAME_LOWER}-${var.env_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = var.ssh_allowed_cidrs
  }
}

# Firewall attachment — separate resource so the firewall ruleset can be
# edited without recreating the server.
resource "hcloud_firewall_attachment" "app" {
  firewall_id = hcloud_firewall.app.id
  server_ids  = [hcloud_server.app.id]
}
