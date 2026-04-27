variable "region" {
  description = "AWS region for all regional resources (VPC, EKS, NAT, CloudWatch Logs, KMS)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as a prefix for related resources (VPC, IAM roles, KMS alias, log group)."
  type        = string
  default     = "sec-lab"

  validation {
    # EKS allows up to 100 chars, but we prefix several dependent resources
    # (IAM roles, subnets, SGs) so keep the same RFC1035-ish shape as the GKE
    # stack to avoid surprise name collisions.
    condition     = can(regex("^[a-z][-a-z0-9]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase, 2-40 chars, start with a letter, end alphanumeric."
  }
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version. Parameterized so this stack can roll forward; keep within the window AWS currently supports (https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group. t3.small = 2 vCPU / 2 GiB, the closest analog to GCP e2-small. Adequate for a typical EDR agent DaemonSet (~500m CPU / 512 Mi–1 GiB memory) plus a few lightweight lab pods. Only consulted when use_spot_instances = false; otherwise see spot_instance_types."
  type        = string
  default     = "t3.small"
}

variable "node_count" {
  description = "Fixed number of nodes in the managed node group. Autoscaling is disabled; change this value to resize."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be between 1 and 3 for a lab footprint."
  }
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size (GiB) for worker nodes. 20 GiB matches the GKE stack; container images for an EDR agent + a handful of lab pods fit comfortably."
  type        = number
  default     = 20
}

variable "use_spot_instances" {
  description = "Use Spot capacity for the managed node group. Spot saves ~60-70% but can be interrupted with a 2-minute warning; fine for a lab."
  type        = bool
  default     = true
}

variable "spot_instance_types" {
  description = "Instance types offered to the Spot fleet. Diversified list (e.g. t3.small/t3a.small/t2.small) improves fill rate when individual types hit capacity ceilings; same-family ~2 GiB sizing keeps scheduling predictable. Only consulted when use_spot_instances = true; on-demand uses var.node_instance_type."
  type        = list(string)
  default     = ["t3.small", "t3a.small", "t2.small"]
  validation {
    condition     = length(var.spot_instance_types) > 0
    error_message = "spot_instance_types must contain at least one instance type."
  }
}

variable "authorized_cidrs" {
  description = "CIDRs allowed to reach the public EKS control plane endpoint. MUST be locked down (typically your workstation /32)."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.authorized_cidrs) > 0
    error_message = "You must provide at least one authorized CIDR. Do not leave the control plane open to 0.0.0.0/0."
  }

  validation {
    condition     = !contains(var.authorized_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted in authorized_cidrs for a lab with intentionally vulnerable workloads."
  }
}

variable "cluster_admin_principal_arns" {
  description = "List of IAM principal ARNs (users or roles) to grant EKS cluster-admin via access entries. Must be non-empty — `bootstrap_cluster_creator_admin_permissions = false` means an empty list produces a cluster with no admins that no one can recover. Typically includes both an operator (your workstation user/role, obtainable via `aws sts get-caller-identity`) AND the mgmt VM's federated role ARN (the `mgmt_vm_role_arn` output of this same stack, from a prior apply — or pre-compute it). BREAKING CHANGE: replaces the singular `cluster_admin_principal_arn` from earlier revisions; operators upgrading need to update terraform.tfvars and may need a `terraform state mv` (see README)."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "cluster_admin_principal_arns must contain at least one ARN. An empty list produces an unusable cluster."
  }

  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/", arn))
    ])
    error_message = "Every entry must be an IAM user or role ARN (arn:aws:iam::<account>:user/... or arn:aws:iam::<account>:role/...)."
  }
}

variable "mgmt_vm_gcp_sa_unique_id" {
  description = "Numeric unique_id of the GCP service account attached to the management VM. Used as the OIDC `sub` in the AWS trust policy for the cross-cloud federated role. Obtain from the gcp-management-tf output `service_account_unique_id`. Empty string disables all federated-access resources in this stack (no OIDC provider, no role, no access entry)."
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

variable "vpc_cidr" {
  description = "Primary CIDR for the lab VPC. Default avoids collision with the GKE lab (10.20.0.0/16) and with the common 10.0.0.0/16 default used by many AWS tutorials."
  type        = string
  default     = "10.30.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of AZs to spread subnets across. EKS control plane requires at least 2 subnets in different AZs. 2 is the lab default; bump to 3 only if you actually need cross-AZ HA."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3 (EKS minimum is 2)."
  }
}

variable "single_nat_gateway" {
  description = "If true, deploy a single NAT Gateway shared by all private subnets. If false, one NAT per AZ (HA, but ~$32/mo/NAT). Lab default is true to minimise spend."
  type        = bool
  default     = true
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch. Off by default to match the lab's cost posture; flip on to forensically investigate traffic from vulnerable pods. When on, only REJECT traffic is logged (cheap, high-signal)."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention for VPC flow logs when enabled. 7 days is the lab default — long enough to investigate an incident, short enough to stay in the CloudWatch free tier."
  type        = number
  default     = 7
}

variable "control_plane_log_retention_days" {
  description = "CloudWatch Logs retention for EKS control plane logs (api/audit/authenticator)."
  type        = number
  default     = 7
}

variable "enable_ebs_csi_driver" {
  description = "Install the managed EBS CSI driver add-on with an IRSA role. Enable if you plan to deploy StatefulSets that provision PVCs (e.g. an EDR agent's helper StatefulSet)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources via the provider's default_tags. AWS tag keys/values are case-sensitive."
  type        = map(string)
  default = {
    environment = "lab"
    purpose     = "security-research"
    managed-by  = "terraform"
  }
}
