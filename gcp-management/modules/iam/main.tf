# Dedicated service account for the management VM.
#
# Principle: this SA is a *discovery* identity. It must be able to:
#   - list all projects in the org (projectViewer)
#   - list all GKE clusters in those projects (container.clusterViewer)
#   - mint short-lived tokens for other SAs the operator may impersonate
#     from the jump box (iam.serviceAccountTokenCreator)
#
# It must NOT hold Editor/Owner. If the operator needs write access to a
# particular resource, they should impersonate a purpose-built SA from the
# VM rather than giving this SA broad write power.
resource "google_service_account" "mgmt_vm" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-vm-sa"
  display_name = "Management VM service account"
  description  = "Attached to the mgmt jump box VM. Least-privilege: discovery + kubeconfig fetch + token creation."
}

locals {
  # Roles bound at the scoped node (org or project).
  # container.clusterViewer: enough for `clusters list` + `get-credentials`
  #                          (grants container.clusters.get + list; does NOT
  #                          grant cluster-internal RBAC — operator still
  #                          needs in-cluster RBAC to actually do anything).
  # resourcemanager.projectViewer: required to enumerate projects across
  #                          the org.
  # iam.serviceAccountTokenCreator: so the operator can `--impersonate-service-account`
  #                          from the VM without copying keys around.
  scoped_roles = [
    "roles/container.clusterViewer",
    "roles/resourcemanager.projectViewer",
    "roles/iam.serviceAccountTokenCreator",
    "roles/compute.viewer",
  ]

  bind_at_org     = var.iam_scope == "organization"
  bind_at_project = var.iam_scope == "project"
}

############################################
# Org-scoped bindings (default)
############################################

resource "google_organization_iam_member" "scoped" {
  for_each = local.bind_at_org ? toset(local.scoped_roles) : toset([])

  org_id = var.org_id
  role   = each.value
  member = "serviceAccount:${google_service_account.mgmt_vm.email}"
}

############################################
# Project-scoped fallback
############################################

resource "google_project_iam_member" "scoped" {
  for_each = local.bind_at_project ? toset(local.scoped_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mgmt_vm.email}"
}

############################################
# Always-project-scoped bindings
############################################

# Writing logs from the VM itself (startup script output, journald) to
# Cloud Logging. Scoped to the host project — logs land there regardless
# of where the SA is also bound.
resource "google_project_iam_member" "logging" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mgmt_vm.email}"
}
