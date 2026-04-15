resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node SA for ${var.cluster_name}"
  description  = "Least-privilege service account attached to GKE nodes."
}

# Minimum roles for a functioning, observable GKE node. Anything broader (e.g.
# roles/editor, default compute SA) would give the vulnerable lab pods too much
# reach via the node metadata server if Workload Identity is ever bypassed.
locals {
  node_sa_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
    "roles/stackdriver.resourceMetadata.writer",
  ]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset(local.node_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}
