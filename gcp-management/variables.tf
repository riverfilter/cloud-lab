############################################
# Identity / placement
############################################

variable "org_id" {
  description = "GCP organization ID. Required — org-level IAM bindings are attached here so the VM's SA can discover GKE clusters across all projects."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{6,}$", var.org_id))
    error_message = "org_id must be a numeric organization ID (digits only, as returned by `gcloud organizations list`)."
  }
}

variable "project_id" {
  description = "Host project that will contain the VM, its service account, disk, and network resources."
  type        = string
}

variable "region" {
  description = "Region for regional resources (subnet, Cloud NAT, router)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the VM instance."
  type        = string
  default     = "us-central1-a"
}

############################################
# VM sizing
############################################

# e2-standard-4 (4 vCPU / 16 GB) is the sweet spot for a Terraform/kubectl/
# occasional-docker-build jump box: bursty workloads on e2 cost roughly half
# of n2 for the same memory footprint, and 16 GB comfortably holds a large
# tfstate refresh plus a few kubectl contexts open in k9s.
variable "machine_type" {
  description = "GCE machine type for the management VM."
  type        = string
  default     = "e2-standard-4"
}

# 100 GB pd-balanced: enough for docker layer cache, tool binaries, a few
# cloned repos, and GKE node image pulls without paying pd-ssd IOPS premium.
variable "disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 100

  validation {
    condition     = var.disk_size_gb >= 30
    error_message = "disk_size_gb must be at least 30 GB — Debian 12 + docker + tooling will not fit comfortably below that."
  }
}

variable "disk_type" {
  description = "Boot disk type. pd-balanced is the default; bump to pd-ssd if you plan heavy docker builds."
  type        = string
  default     = "pd-balanced"
}

variable "image_family" {
  description = "GCE image family. debian-12 is required per the spec; exposed as a variable for testing only."
  type        = string
  default     = "debian-12"
}

variable "image_project" {
  description = "Project that hosts the image family."
  type        = string
  default     = "debian-cloud"
}

############################################
# Security posture
############################################

variable "allow_public_ip" {
  description = "If true, attach an ephemeral external IP to the VM. Default false — access via IAP tunnel is preferred. Firewall stays locked to IAP CIDR regardless."
  type        = bool
  default     = false
}

variable "enable_confidential" {
  description = "Enable Confidential VM (AMD SEV). Default off; incurs a modest cost premium and restricts machine families."
  type        = bool
  default     = false
}

variable "enable_secure_boot" {
  description = "Enable Shielded VM secure boot."
  type        = bool
  default     = true
}

############################################
# OS / user
############################################

variable "vm_username" {
  description = "Primary OS user created inside the VM (dotfiles, kubeconfig, docker/sudo group membership target)."
  type        = string
  default     = "devops"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.vm_username))
    error_message = "vm_username must be a valid POSIX username."
  }
}

variable "dotfiles_repo" {
  description = "HTTPS URL of the dotfiles repo to clone. Supports either `stow` layout or an `install.sh` convention — bootstrap prefers install.sh if present, else falls back to stow."
  type        = string
  default     = "https://github.com/REPLACE-ME/dotfiles.git"
}

variable "dotfiles_branch" {
  description = "Branch to check out from the dotfiles repo."
  type        = string
  default     = "main"
}

############################################
# Networking
############################################

variable "create_network" {
  description = "Create a dedicated VPC + subnet + Cloud NAT. If false, you must provide network_self_link and subnet_self_link."
  type        = bool
  default     = true
}

variable "network_self_link" {
  description = "Self-link of a pre-existing VPC. Ignored when create_network = true."
  type        = string
  default     = ""
}

variable "subnet_self_link" {
  description = "Self-link of a pre-existing subnet. Ignored when create_network = true."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "CIDR for the management subnet (only used when create_network = true)."
  type        = string
  default     = "10.10.0.0/24"
}

############################################
# IAM scope
############################################

variable "iam_scope" {
  description = "Where to bind the discovery roles: `organization` (default, broadest discovery) or `project` (host project only, limits GKE discovery to that project)."
  type        = string
  default     = "organization"

  validation {
    condition     = contains(["organization", "project"], var.iam_scope)
    error_message = "iam_scope must be either 'organization' or 'project'."
  }
}

############################################
# Labels / naming
############################################

variable "name_prefix" {
  description = "Prefix applied to all named resources."
  type        = string
  default     = "mgmt"
}

variable "labels" {
  description = "Labels applied to all labelable resources. environment / team / service / cost-center expected."
  type        = map(string)
  default = {
    environment = "mgmt"
    team        = "platform"
    service     = "mgmt-vm"
    cost-center = "platform-ops"
    managed-by  = "terraform"
  }
}
