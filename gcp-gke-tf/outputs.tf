output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "GKE cluster location (zone for zonal clusters)."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded GKE cluster CA certificate."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "node_service_account_email" {
  description = "Email of the least-privilege node service account."
  value       = google_service_account.nodes.email
}

output "network_name" {
  description = "VPC network name."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Node subnet name."
  value       = google_compute_subnetwork.nodes.name
}

output "kubectl_configure_command" {
  description = "Run this to populate ~/.kube/config for the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${google_container_cluster.this.location} --project ${var.project_id}"
}
