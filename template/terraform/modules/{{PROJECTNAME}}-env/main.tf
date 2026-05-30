# Cloud-init rendering.
#
# `templatefile()` resolves the template at plan time and produces the
# `user_data` string consumed by `hcloud_server.app` (in vm.tf). The file
# MUST exist at validate time or `terraform validate` fails.
#
# Inputs passed to the template:
#   - operator_ssh_pubkeys: list of pubkey strings (we pass `values(...)`
#     because the template iterates over a list).
#   - env_name: used in the cloud-init `final_message` for operator clarity
#     in `cloud-init status --long`.

locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    operator_ssh_pubkeys = values(var.operator_ssh_pubkeys)
    env_name             = var.env_name
  })
}
