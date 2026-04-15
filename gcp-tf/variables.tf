variable "project_id" {
  description = "GCP project ID to deploy the lab cluster into."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must be set."
  }
}

variable "region" {
  description = "GCP region for regional resources (VPC subnet, Cloud Router, Cloud NAT)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the zonal GKE cluster and its node pool."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "GKE cluster name. Also used as a prefix for related resources."
  type        = string
  default     = "sec-lab"

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be RFC1035-compliant (lowercase, 2-40 chars, start letter, end alphanumeric)."
  }
}

variable "node_machine_type" {
  description = "Machine type for node pool VMs. e2-small = 2 vCPU / 2 GiB, adequate for SentinelOne (~500m/512Mi-1Gi) plus a few lightweight lab pods."
  type        = string
  default     = "e2-small"
}

variable "node_count" {
  description = "Fixed number of nodes in the pool. Autoscaling is disabled; change this value to resize."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be between 1 and 3 for a lab footprint."
  }
}

variable "use_spot_vms" {
  description = "Use Spot VMs for node pool. Spot saves ~60-91% but can be preempted; fine for a lab."
  type        = bool
  default     = true
}

variable "authorized_cidrs" {
  description = "CIDRs allowed to reach the public GKE control plane endpoint. MUST be locked down (typically your workstation /32)."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []

  validation {
    condition     = length(var.authorized_cidrs) > 0
    error_message = "You must provide at least one authorized CIDR. Do not leave the control plane open to 0.0.0.0/0."
  }

  validation {
    condition     = !contains([for c in var.authorized_cidrs : c.cidr_block], "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted in authorized_cidrs for a lab with intentionally vulnerable workloads."
  }
}

variable "subnet_cidr" {
  description = "Primary CIDR for the node subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary range for GKE pods."
  type        = string
  default     = "10.21.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for GKE services."
  type        = string
  default     = "10.22.0.0/20"
}

variable "master_ipv4_cidr_block" {
  description = "CIDR used for the GKE control plane private endpoint VPC peering. Must be a /28."
  type        = string
  default     = "172.16.0.0/28"
}

variable "labels" {
  description = "Labels applied to all resources that support them (and used for GKE cost allocation)."
  type        = map(string)
  default = {
    environment = "lab"
    purpose     = "security-research"
    managed-by  = "terraform"
  }
}
