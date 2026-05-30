# Output names mirror the staging root's exported names exactly (including
# the deliberate `spa_hostname` alias for runbook + workflow compatibility),
# so the same per-env wrapper workflows and the runbook can reference
# `terraform output -raw <name>` without env-specific branching.

output "vm_ipv4" {
  description = "Primary IPv4 of the env VM (sticky across server replacement)."
  value       = module.${PROJECT_NAME_LOWER}_env.vm_ipv4
  sensitive   = false
}

output "vm_ipv6" {
  description = "Primary IPv6 of the env VM (Hetzner /64 native allocation)."
  value       = module.${PROJECT_NAME_LOWER}_env.vm_ipv6
  sensitive   = false
}

output "ssh_command" {
  description = "Ready-to-paste SSH command for the deploy user."
  value       = module.${PROJECT_NAME_LOWER}_env.ssh_command
  sensitive   = false
}

output "spa_hostname" {
  description = "Fully-qualified hostname for the SPA edge. Deliberate alias preserved from staging for runbook + workflow compatibility."
  value       = module.${PROJECT_NAME_LOWER}_env.app_hostname
  sensitive   = false
}

output "api_hostname" {
  description = "Fully-qualified hostname for the API edge."
  value       = module.${PROJECT_NAME_LOWER}_env.api_hostname
  sensitive   = false
}
