output "vm_ipv4" {
  description = "Primary IPv4 of the env VM (sticky across server replacement)."
  value       = hcloud_primary_ip.app.ip_address
  sensitive   = false
}

output "vm_ipv6" {
  description = "Primary IPv6 of the env VM (Hetzner /64 native allocation, exposed by hcloud_server)."
  value       = hcloud_server.app.ipv6_address
  sensitive   = false
}

output "ssh_command" {
  description = "Ready-to-paste SSH command for the deploy user. Operator's pubkey must be in `operator_ssh_pubkeys`."
  value       = "ssh deploy@${hcloud_primary_ip.app.ip_address}"
  sensitive   = false
}

output "app_hostname" {
  description = "Fully-qualified hostname for the SPA edge. Either the operator-supplied `app_hostname` or an sslip.io fallback derived from the primary IPv4."
  value       = local.app_hostname
  sensitive   = false
}

output "api_hostname" {
  description = "Fully-qualified hostname for the API edge. Either the operator-supplied `api_hostname` or an sslip.io fallback derived from the primary IPv4."
  value       = local.api_hostname
  sensitive   = false
}

output "firewall_id" {
  description = "Hetzner Cloud firewall ID for the env. Useful for ad-hoc rule edits or external attachments."
  value       = hcloud_firewall.app.id
  sensitive   = false
}

output "server_id" {
  description = "Hetzner Cloud server ID for the env VM. Useful for operator scripts that need the numeric ID (e.g., `hcloud server describe <id>`)."
  value       = hcloud_server.app.id
  sensitive   = false
}
