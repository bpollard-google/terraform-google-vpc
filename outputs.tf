output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.this.name
}

output "network_self_link" {
  description = "URI of the VPC network."
  value       = google_compute_network.this.self_link
}

output "network_id" {
  description = "Terraform identifier for the VPC network."
  value       = google_compute_network.this.id
}

output "subnet_self_links" {
  description = "Map of the subnet key supplied in var.subnets to the subnet's URI. The key is the supplied key, which differs from the created name when subnet_name_prefix is set."
  value       = { for name, subnet in google_compute_subnetwork.this : name => subnet.self_link }
}

output "subnet_names" {
  description = "Map of the subnet key supplied in var.subnets to the name actually created, which differs when subnet_name_prefix is set."
  value       = { for name, subnet in google_compute_subnetwork.this : name => subnet.name }
}
