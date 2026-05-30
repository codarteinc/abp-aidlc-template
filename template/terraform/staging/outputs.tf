# Output names preserved exactly across envs so downstream consumers
# (operator runbooks, `terraform output` calls in rebootstrap.sh + GH
# Actions workflows) keep working without env-specific branching.
#
# Note the deliberate alias: the module exports `app_hostname`, but the
# root forwards it as `spa_hostname` — the historical staging name that
# unit-08's deploy workflows still use.

output "vm_ipv4" {
  description = "Primary IPv4 of the staging VM (sticky across server replacement)."
  value       = module.${PROJECT_NAME_LOWER}_env.vm_ipv4
  sensitive   = false
}

output "vm_ipv6" {
  description = "Primary IPv6 of the staging VM (Hetzner /64 native allocation)."
  value       = module.${PROJECT_NAME_LOWER}_env.vm_ipv6
  sensitive   = false
}

output "ssh_command" {
  description = "Ready-to-paste SSH command for the deploy user."
  value       = module.${PROJECT_NAME_LOWER}_env.ssh_command
  sensitive   = false
}

output "spa_hostname" {
  description = "Fully-qualified hostname for the SPA edge. Deliberate alias — the module's internal name is `app_hostname`, but the runbook + unit-08 workflows still call it `spa_hostname`."
  value       = module.${PROJECT_NAME_LOWER}_env.app_hostname
  sensitive   = false
}

output "api_hostname" {
  description = "Fully-qualified hostname for the API edge. Either the operator-supplied `api_hostname` or an sslip.io fallback derived from the primary IPv4."
  value       = module.${PROJECT_NAME_LOWER}_env.api_hostname
  sensitive   = false
}
