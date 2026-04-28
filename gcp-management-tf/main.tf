locals {
  # Normalized name prefix used for resource naming.
  prefix = var.name_prefix

  # Resolve network/subnet references: if we created them here, use the
  # module outputs; otherwise the caller supplied self-links.
  network_self_link = var.create_network ? module.network[0].network_self_link : var.network_self_link
  subnet_self_link  = var.create_network ? module.network[0].subnet_self_link : var.subnet_self_link

  ##########################################
  # Cross-stack federation map composition
  ##########################################
  #
  # Each effective map = (entries derived from cluster-stack remote
  # state) merged with (explicit-map entries from tfvars). The explicit
  # map is the second arg to `merge()`, so on key collision the
  # explicit value wins — this lets an operator override a single
  # label without abandoning the remote-state path. Entries are
  # filtered out when the underlying cluster stack hasn't yet rendered
  # `mgmt_vm_role_arn` / `mgmt_vm_app_client_id` (e.g. when the cluster
  # stack was applied with `mgmt_vm_gcp_sa_unique_id` unset) so we
  # don't write null IAM principals into federated-principals.json.

  aws_role_arns_from_state = {
    for label, rs in data.terraform_remote_state.aws_eks :
    label => rs.outputs.mgmt_vm_role_arn
    if try(rs.outputs.mgmt_vm_role_arn, null) != null
  }
  aws_role_arns_effective = merge(local.aws_role_arns_from_state, var.aws_role_arns)

  azure_federated_apps_from_state = {
    for label, rs in data.terraform_remote_state.azure_aks :
    label => {
      client_id        = rs.outputs.mgmt_vm_app_client_id
      tenant_id        = rs.outputs.mgmt_vm_tenant_id
      subscription_ids = []
    }
    # tenant_id-null check is presently a tautology (the cluster stack
    # sources tenant_id from data.azurerm_client_config.current which is
    # always populated) — kept as defence-in-depth against producer-side
    # refactors that could change the contract.
    if try(rs.outputs.mgmt_vm_app_client_id, null) != null
    && try(rs.outputs.mgmt_vm_tenant_id, null) != null
  }
  azure_federated_apps_effective = merge(local.azure_federated_apps_from_state, var.azure_federated_apps)
}

############################################
# Required APIs on the host project
############################################

# Enable the APIs this stack touches. `disable_on_destroy = false` is
# deliberate — disabling APIs on destroy is destructive across a shared
# project and almost never what you want.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "container.googleapis.com",
    "serviceusage.googleapis.com",
    "oslogin.googleapis.com",
  ])

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

############################################
# Submodules
############################################

module "iam" {
  source = "./modules/iam"

  org_id      = var.org_id
  project_id  = var.project_id
  name_prefix = local.prefix
  iam_scope   = var.iam_scope

  depends_on = [google_project_service.required]
}

module "network" {
  count  = var.create_network ? 1 : 0
  source = "./modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.prefix
  subnet_cidr = var.subnet_cidr

  depends_on = [google_project_service.required]
}

module "mgmt_vm" {
  source = "./modules/mgmt-vm"

  project_id          = var.project_id
  zone                = var.zone
  name_prefix         = local.prefix
  machine_type        = var.machine_type
  disk_size_gb        = var.disk_size_gb
  disk_type           = var.disk_type
  image_family        = var.image_family
  image_project       = var.image_project
  network_self_link   = local.network_self_link
  subnet_self_link    = local.subnet_self_link
  service_account     = module.iam.service_account_email
  allow_public_ip     = var.allow_public_ip
  enable_confidential = var.enable_confidential
  enable_secure_boot  = var.enable_secure_boot
  labels              = var.labels

  # Rendered startup script.
  #
  # The federated-principals payload is rendered to JSON here and embedded
  # verbatim via a heredoc in the template. Keeping the JSON generation on
  # the Terraform side (jsonencode) rather than assembling it in shell
  # means we never have to quote-escape AWS ARNs or Azure GUIDs manually.
  startup_script = templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    vm_username     = var.vm_username
    dotfiles_repo   = var.dotfiles_repo
    dotfiles_branch = var.dotfiles_branch
    federated_principals_json = jsonencode({
      aws_role_arns        = local.aws_role_arns_effective
      aws_regions          = var.aws_regions
      azure_federated_apps = local.azure_federated_apps_effective
    })
  })

  depends_on = [
    module.iam,
    module.network,
    google_project_service.required,
  ]
}
