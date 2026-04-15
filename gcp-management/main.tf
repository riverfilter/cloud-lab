locals {
  # Normalized name prefix used for resource naming.
  prefix = var.name_prefix

  # Resolve network/subnet references: if we created them here, use the
  # module outputs; otherwise the caller supplied self-links.
  network_self_link = var.create_network ? module.network[0].network_self_link : var.network_self_link
  subnet_self_link  = var.create_network ? module.network[0].subnet_self_link : var.subnet_self_link
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
  startup_script = templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    vm_username     = var.vm_username
    dotfiles_repo   = var.dotfiles_repo
    dotfiles_branch = var.dotfiles_branch
  })

  depends_on = [
    module.iam,
    module.network,
    google_project_service.required,
  ]
}
