locals {
  # When the operator hasn't supplied a real DNS hostname, fall back to
  # sslip.io: "app.5-75-123-45.sslip.io" resolves to 5.75.123.45 via
  # sslip.io's public wildcard DNS. Useful for zero-DNS-setup smoke tests;
  # operators should set real hostnames before any external user uses the
  # environment.
  ip_dashed = replace(hcloud_primary_ip.app.ip_address, ".", "-")

  app_hostname = var.app_hostname != "" ? var.app_hostname : "app.${local.ip_dashed}.sslip.io"
  api_hostname = var.api_hostname != "" ? var.api_hostname : "api.${local.ip_dashed}.sslip.io"
}
