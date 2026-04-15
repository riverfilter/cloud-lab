output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "subnet_self_link" {
  value = google_compute_subnetwork.this.self_link
}

output "network_name" {
  value = google_compute_network.this.name
}
