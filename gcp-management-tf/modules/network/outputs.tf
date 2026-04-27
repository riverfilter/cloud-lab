output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "subnet_self_link" {
  value = google_compute_subnetwork.this.self_link
}

output "network_name" {
  value = google_compute_network.this.name
}

output "nat_public_ip" {
  description = "Static egress IP reserved for Cloud NAT. Stable across NAT rebuilds so it can be pinned in cluster control-plane allowlists."
  value       = google_compute_address.nat.address
}
