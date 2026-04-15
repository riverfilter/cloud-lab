output "instance_name" {
  value = google_compute_instance.mgmt.name
}

output "instance_zone" {
  value = google_compute_instance.mgmt.zone
}

output "internal_ip" {
  value = google_compute_instance.mgmt.network_interface[0].network_ip
}

output "external_ip" {
  value = try(google_compute_instance.mgmt.network_interface[0].access_config[0].nat_ip, null)
}

output "self_link" {
  value = google_compute_instance.mgmt.self_link
}
