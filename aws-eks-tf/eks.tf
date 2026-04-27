data "aws_caller_identity" "current" {}

# Customer-managed KMS key for envelope encryption of Kubernetes secrets.
# EKS will wrap the DEK produced by the control plane with this CMK; secrets
# at rest in etcd are ciphertext under that wrap. Rotation is enabled —
# rotated key material is used for new writes while the old material stays
# available for decrypt, so this is zero-downtime.
resource "aws_kms_key" "eks" {
  description             = "EKS secrets envelope encryption for ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # Shortest allowed — this is a lab, not prod.

  # Default key policy: root account has full control. EKS is granted Encrypt/
  # Decrypt implicitly via the cluster role's AWS-managed policy + the key
  # grant that EKS creates on first use. We don't need to hand-craft EKS
  # permissions here.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# CloudWatch log group for control plane logs. EKS will create this on its
# own when you enable logging, but managing it explicitly lets us pin
# retention (default EKS-created groups have Never Expire, which quietly
# accrues cost over months).
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.control_plane_log_retention_days
}

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Additional SG for the EKS control plane ENIs. EKS creates its own managed SG; this is for allowlisting in-VPC sources if needed."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  # Access entries (API) replace the legacy aws-auth ConfigMap. API_AND_CONFIG_MAP
  # would keep ConfigMap compatibility for third-party tools that still write
  # to it; we go API-only because this stack is greenfield and the ConfigMap
  # surface is footgun-prone.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    # Spread control plane ENIs across private subnets in each AZ. Public
    # subnets are NOT passed — the control plane doesn't need to live there,
    # and putting it in private-only subnets reduces the cluster-facing
    # attack surface.
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true # Private endpoint ON so in-VPC workloads (and a future bastion) don't hairpin through NAT.
    endpoint_public_access  = true # Public endpoint ON but locked down below.
    public_access_cidrs     = var.authorized_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # Envelope-encrypt Kubernetes Secrets with the CMK created above. This is
  # the EKS equivalent of GKE application-layer secrets encryption.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Equivalent of GKE's SYSTEM_COMPONENTS + WORKLOADS logging components.
  # - api:           control plane API server requests
  # - audit:         kube-audit log (crucial for security research)
  # - authenticator: who authenticated and via which identity
  # scheduler + controllerManager logs are noisy and rarely useful in a lab.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}

# Bootstrap cluster-admin access entries. Without these (and with
# bootstrap_cluster_creator_admin_permissions = false), nobody can kubectl
# into the cluster after creation. cluster_admin_principal_arns is validated
# non-empty and typically contains two entries: the operator's workstation
# IAM user/role ARN AND the mgmt VM's federated role ARN (the
# `mgmt_vm_role_arn` output of this stack). Both get full cluster-admin
# scope — anything narrower defeats the purpose of the lab's single kubectl
# entry point.
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# Security group for the node group. EKS creates its own cluster-level SG
# and attaches it to nodes via the managed node group, so we only need this
# for extra rules (intentionally none today — rely on VPC CNI + NetworkPolicy
# for pod-level controls).
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "Additional SG for EKS worker nodes. Empty by default; add rules here for lab-specific east-west allowlists."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name                                        = "${var.cluster_name}-nodes-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Launch template so we can enforce IMDSv2 and control the EBS root volume.
# The GKE equivalent of disable-legacy-endpoints is http_tokens = required.
# http_put_response_hop_limit = 2 is the EKS-recommended value: hop limit 1
# blocks containers running in the default bridged pod network from reaching
# IMDS at all, which breaks the VPC CNI and most AWS SDK-in-pod patterns.
# Hop limit 2 still defeats the SSRF-to-credentials attacks that IMDSv1
# enabled (IMDSv2 required is the real control), while not breaking pod
# networking.
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Launch template for ${var.cluster_name} managed node group: IMDSv2-only, gp3 root, standard tags."

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3" # gp3 is cheaper per GiB than gp2 and has baseline 3k IOPS / 125 MB/s independent of size.
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Explicit tag propagation to the instance + attached volumes so cost
  # allocation reports surface node-level spend. ASG tags do NOT auto-
  # propagate to pod-visible labels — that differs from GKE, where node
  # labels surface inside the pod. If you need pod-visible node metadata,
  # apply it via kubelet --node-labels (EKS managed node groups don't expose
  # that flag directly; you'd use the `labels` argument on the node group).
  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-node-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Managed node group. Autoscaling is deliberately disabled (min = max =
# desired = node_count) for the same reason the GKE stack disables it: a
# compromised pod triggering surprise scale-up would be expensive and noisy.
#
# Instance type rationale matches the GKE e2-small discussion:
#   - t3.nano (0.5 GiB) / t3.micro (1 GiB): system pods + kubelet already
#     consume most of that; a typical EDR agent (~512 Mi–1 GiB) will OOM.
#   - t3.small (2 GiB): comfortable fit for an EDR agent + a few lab pods.
#   - t3.medium (4 GiB): ~2x cost with no benefit for this footprint.
# t3a.small (AMD) is ~10% cheaper if you don't care about Intel-specific
# benchmarks. Parameterize via node_instance_type.
resource "aws_eks_node_group" "primary" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-primary"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  capacity_type  = var.use_spot_instances ? "SPOT" : "ON_DEMAND"
  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  # AL2023 is the current EKS default. AL2 is deprecated on 1.33+ and Bottlerocket
  # is an option if you want an immutable host OS down the line.
  ami_type = "AL2023_x86_64_STANDARD"

  labels = {
    "node.kubernetes.io/lifecycle" = var.use_spot_instances ? "spot" : "on-demand"
    "lab.purpose"                  = "security-research"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  lifecycle {
    ignore_changes = [
      # AL2023 AMI IDs roll forward within the release channel; ignore so
      # Terraform doesn't fight with EKS managed upgrades.
      scaling_config[0].desired_size,
    ]
  }
}

# Managed add-ons. Pinning `addon_version = null` lets EKS pick the default
# compatible version for the cluster's Kubernetes minor; explicit pinning is
# the right call for prod but overkill for a lab where the cluster_version
# variable itself is what you'd bump.
#
# vpc-cni: enableNetworkPolicy = true turns on native NetworkPolicy support
# (AWS VPC CNI 1.14+). This is the AWS equivalent of GKE Dataplane V2's
# network-policy enforcement — mandatory for a lab that hosts deliberately
# vulnerable workloads.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  depends_on = [aws_eks_node_group.primary]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.primary]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.primary]
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi[0].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.primary]
}
