variable "subscription_id" {
  description = "Azure subscription ID (GUID) to deploy the lab cluster into. Explicit rather than ARM_SUBSCRIPTION_ID env so it is reviewable in every plan."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription GUID."
  }
}

variable "location" {
  description = "Azure region for all regional resources (Resource Group, VNet, AKS, NAT Gateway, Log Analytics)."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the dedicated resource group for this stack. AKS will auto-create a separate node resource group (MC_...) for the VMSS + LB + NSG; that one is named via node_resource_group."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "AKS cluster name. Also used as a prefix for related resources (VNet, subnet, NAT gateway, identity, RG). Must be unique within the AAD tenant because the federated AAD App display_name derives from it (<cluster_name>-mgmt-vm) — AAD does not enforce uniqueness on display_name, but two clusters with the same value in the same tenant produce ambiguous CLI listings (`az ad app list --display-name ...` returns multiple objects) and operators filtering by display_name will hit the wrong App."
  type        = string
  default     = "sec-lab"

  validation {
    # AKS name: 1-63 chars, alphanumeric + hyphen, must start and end alphanumeric.
    # We keep the same RFC1035-ish 2-40 shape as the GKE / EKS stacks so
    # dependent resource names (identity, NSG, etc.) do not collide with
    # Azure's per-resource name-length quirks.
    condition     = can(regex("^[a-z0-9][-a-z0-9]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric or hyphen, 2-40 chars, start and end alphanumeric."
  }
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version. Keep within the window AKS currently supports (https://learn.microsoft.com/azure/aks/supported-kubernetes-versions)."
  type        = string
  default     = "1.30"
}

variable "sku_tier" {
  description = "AKS control plane SKU tier. Free (default) has no SLA and is intended for labs/dev. Standard is $0.10/hr and adds a 99.95% uptime SLA. Premium adds long-term support for a higher price."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of Free, Standard, Premium."
  }
}

variable "node_vm_size" {
  description = "VM size for AKS node pool. Standard_B2s = 2 vCPU burstable / 4 GiB RAM, the closest cost-equivalent to GCP e2-small on Azure (Azure has no 2 GiB burstable at this tier; the extra 2 GiB is headroom for a typical EDR agent DaemonSet). Switch to Standard_D2ads_v5 for non-burstable at ~1.7x cost."
  type        = string
  default     = "Standard_B2s"
}

variable "node_count" {
  description = "Fixed number of nodes in the default node pool. Autoscaling is disabled; change this value to resize."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be between 1 and 3 for a lab footprint."
  }
}

variable "node_disk_size_gb" {
  description = "OS disk size (GiB) for node VMs. 30 GiB is the AKS minimum; container images for an EDR agent + a handful of lab pods fit comfortably."
  type        = number
  default     = 30

  validation {
    condition     = var.node_disk_size_gb >= 30
    error_message = "AKS requires OS disk size >= 30 GiB."
  }
}

variable "use_spot_vms" {
  description = "If true, add a second user node pool using Azure Spot VMs. AKS does NOT allow the system node pool to be Spot, so turning this on produces a two-pool topology (1x system B2s on-demand + Spot user pool). Default false to keep the single-pool simplicity and match the GKE cost ceiling; flip to true only if the extra ~$30/mo system pool is acceptable."
  type        = bool
  default     = false
}

variable "spot_node_vm_size" {
  description = "VM size for the Spot user pool (only used when use_spot_vms = true). Default matches node_vm_size for predictable sizing."
  type        = string
  default     = "Standard_B2s"
}

variable "spot_node_count" {
  description = "Node count for the Spot user pool (only used when use_spot_vms = true)."
  type        = number
  default     = 1

  validation {
    condition     = var.spot_node_count >= 1 && var.spot_node_count <= 3
    error_message = "spot_node_count must be between 1 and 3."
  }
}

# Variable name is intentionally `authorized_cidrs` across all three sibling
# stacks (gcp-gke-tf, aws-eks-tf, azure-aks-tf) — the gcp-management-tf
# `nat_public_ip` output description tells operators to append `<NAT_IP>/32`
# to "each cluster stack's authorized_cidrs" by that exact name. Do NOT
# rename to mirror the cloud-native field (azurerm's
# `api_server_authorized_ip_ranges`); the cross-stack instruction in
# gcp-management-tf/outputs.tf would silently drift.
variable "authorized_cidrs" {
  description = "CIDRs allowed to reach the public AKS API server endpoint. MUST be locked down (typically your workstation /32). 0.0.0.0/0 is rejected by validation."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.authorized_cidrs) > 0
    error_message = "You must provide at least one authorized CIDR. Do not leave the API server open to 0.0.0.0/0."
  }

  validation {
    condition     = !contains(var.authorized_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted in authorized_cidrs for a lab with intentionally vulnerable workloads."
  }
}

variable "admin_group_object_ids" {
  description = "AAD group object IDs (GUIDs) that receive cluster-admin via Azure RBAC for Kubernetes. At least one is required because local_account_disabled = true by default. Find yours with `az ad group show --group <name> --query id -o tsv`."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.admin_group_object_ids) > 0
    error_message = "admin_group_object_ids must contain at least one AAD group GUID (local accounts are disabled by default)."
  }

  validation {
    condition = alltrue([
      for g in var.admin_group_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", g))
    ])
    error_message = "Every admin_group_object_ids entry must be an AAD object GUID."
  }
}

variable "local_account_disabled" {
  description = "If true, disable the local Kubernetes admin account (--admin kubeconfig). This forces AAD-backed auth and is the safer posture for a lab with intentionally vulnerable workloads. Flip off only if you specifically need the break-glass kubeconfig."
  type        = bool
  default     = true
}

variable "mgmt_vm_gcp_sa_unique_id" {
  description = "Numeric unique_id of the GCP service account attached to the management VM. Used as the OIDC `sub` in the AAD federated credential on the mgmt VM's AAD App. Obtain from the gcp-management-tf output `service_account_unique_id`. Empty string disables all federated-access resources in this stack (no AAD App, no SP, no RBAC)."
  type        = string
  default     = ""

  validation {
    # GCP SA unique_id is a ~21-digit decimal string. Accept empty (disabled)
    # or any all-digits value of reasonable length to catch obvious mistakes
    # like pasting the SA email by accident.
    condition     = var.mgmt_vm_gcp_sa_unique_id == "" || can(regex("^[0-9]{15,32}$", var.mgmt_vm_gcp_sa_unique_id))
    error_message = "mgmt_vm_gcp_sa_unique_id must be empty, or the numeric unique_id of the GCP SA (15-32 digits). Do not pass the SA email."
  }
}

variable "vnet_cidr" {
  description = "Primary CIDR for the lab VNet. Default avoids collision with GKE (10.20.0.0/16), EKS (10.30.0.0/16), and the common 10.0.0.0/16 Azure default."
  type        = string
  default     = "10.40.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = "CIDR for the node subnet within the VNet. Must fit inside vnet_cidr."
  type        = string
  default     = "10.40.0.0/20"
}

variable "pod_cidr" {
  description = "CIDR for pod IPs. With Azure CNI Overlay, this range is NOT part of the VNet (mirrors GKE's secondary pod range)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes ClusterIP services. Must not overlap vnet_cidr or pod_cidr. dns_service_ip is derived from this as the .10 address."
  type        = string
  default     = "10.41.0.0/16"
}

variable "enable_diagnostics" {
  description = "If true, create a Log Analytics workspace and wire AKS diagnostic settings (kube-audit, kube-apiserver, kube-controller-manager) to it. Off by default — Log Analytics ingestion is billed per-GB and can rapidly dominate lab cost."
  type        = bool
  default     = false
}

variable "diagnostics_retention_days" {
  description = "Retention for AKS diagnostic logs in Log Analytics when enabled. 30 days is the workspace default; keep short for lab cost."
  type        = number
  default     = 30
}

variable "enable_monitor_metrics" {
  description = "If true, enable the monitor_metrics block on AKS (Azure Monitor managed Prometheus). Off by default — expensive for a lab footprint and typically overlaps with whatever an in-cluster EDR agent already collects."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in the stack. Azure tag keys/values are case-sensitive."
  type        = map(string)
  default = {
    environment = "lab"
    purpose     = "security-research"
    managed-by  = "terraform"
  }
}
