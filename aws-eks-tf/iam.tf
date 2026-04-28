# EKS cluster role — assumed by the EKS control plane itself. The managed
# policy is narrow (describe EC2, manage ENIs for the control plane) and is
# the AWS-recommended baseline.
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Node IAM role — least privilege. Only the three policies strictly required
# for a functioning managed node group:
#   - AmazonEKSWorkerNodePolicy: kubelet calls to EKS, ECR auth for node image.
#   - AmazonEKS_CNI_Policy: VPC CNI needs to attach ENIs + assign secondary
#     IPs. This policy is BROAD (ec2:AssignPrivateIpAddresses, etc.) and a
#     compromised node could abuse it. The proper fix is IRSA for the
#     aws-node ServiceAccount instead of attaching to the node role; that is
#     explicitly a roadmap item — see roadmap.md.
#   - AmazonEC2ContainerRegistryReadOnly: pull container images from ECR.
# Anything broader (e.g. AmazonSSMManagedInstanceCore, CloudWatchAgentPolicy)
# would give compromised pods more reach through the IMDS-exposed node role.
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# OIDC provider for IRSA (IAM Roles for Service Accounts — the AWS equivalent
# of GKE Workload Identity). Without this, pods cannot assume IAM roles via
# the projected service-account token.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# EBS CSI driver IRSA role. The AWS-managed policy is scoped to volumes
# tagged by the driver; broad enough to provision PVCs, narrow enough that a
# compromised pod cannot arbitrarily attach volumes to other instances.
data "aws_iam_policy_document" "ebs_csi_assume" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume[0].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# Cross-cloud federated identity for the mgmt VM (GCP -> AWS WIF).
#
# The mgmt VM running on GCP signs a JWT with its attached GCP SA, AWS STS
# validates it against this OIDC provider, and returns short-lived creds
# for the role below. No static AWS access keys ever touch the VM.
#
# All resources in this block are count-gated on var.mgmt_vm_gcp_sa_unique_id
# being non-empty, so an apply without the variable set is a clean no-op.
# ---------------------------------------------------------------------------

# Pull Google's current certificate chain dynamically rather than hardcoding
# the thumbprint. Same pattern as data.tls_certificate.oidc above (the EKS
# IRSA provider), so rotation of Google's CA is a re-apply away. AWS still
# requires a thumbprint on the OIDC provider resource even though it no
# longer uses it to validate tokens for IAM's trusted root CAs — we supply
# the current cert SHA-1 so the field is never stale.
#
# The data source is additionally count-gated on var.gcp_oidc_thumbprint
# being empty: when an operator pins the thumbprint via that variable
# (e.g. for an air-gapped CI runner that cannot reach accounts.google.com
# at plan time) we skip the outbound TLS handshake entirely.
data "tls_certificate" "gcp_oidc" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" || var.gcp_oidc_thumbprint != "" ? 0 : 1

  url = "https://accounts.google.com"
}

# OIDC provider for GCP. client_id_list = ["sts.amazonaws.com"] matches the
# "aud" claim AWS STS requires for AssumeRoleWithWebIdentity.
resource "aws_iam_openid_connect_provider" "gcp" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  url            = "https://accounts.google.com"
  client_id_list = ["sts.amazonaws.com"]
  # Operator-pinned thumbprint takes precedence (avoids plan-time TLS handshake
  # to accounts.google.com); otherwise index the chain root (last cert) of the
  # dynamically-fetched chain — AWS expects the top-most CA thumbprint.
  thumbprint_list = [
    var.gcp_oidc_thumbprint != "" ? var.gcp_oidc_thumbprint : data.tls_certificate.gcp_oidc[0].certificates[length(data.tls_certificate.gcp_oidc[0].certificates) - 1].sha1_fingerprint
  ]
}

# Role the GCP SA can assume. Trust policy pins both the subject (GCP SA
# unique_id) and the audience (STS), so any other GCP principal minting a
# Google-issued ID token cannot assume this role.
resource "aws_iam_role" "mgmt_vm_federated" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  name = "${var.cluster_name}-mgmt-vm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.gcp[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "accounts.google.com:aud" = "sts.amazonaws.com"
          "accounts.google.com:sub" = var.mgmt_vm_gcp_sa_unique_id
        }
      }
    }]
  })
}

# Minimum set of EKS API permissions for the mgmt VM to discover and
# kubectl into the cluster. sts:GetCallerIdentity is included because
# `aws sts get-caller-identity` is the canonical smoke test after an
# AssumeRoleWithWebIdentity call and several debug tools invoke it
# implicitly — it leaks no authorization surface on its own.
resource "aws_iam_role_policy" "mgmt_vm_federated" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  name = "${var.cluster_name}-mgmt-vm"
  role = aws_iam_role.mgmt_vm_federated[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters",
        "sts:GetCallerIdentity",
      ]
      Resource = "*"
    }]
  })
}

# NOTE: access-entry / policy-association wiring for the mgmt VM role was
# consolidated into the for_each'd `aws_eks_access_entry.admin` +
# `aws_eks_access_policy_association.admin` pair in eks.tf. The operator is
# expected to pass the mgmt VM role ARN (see the `mgmt_vm_role_arn` output)
# as one of the entries in var.cluster_admin_principal_arns. Operators
# upgrading from a revision that still had these resources must migrate
# state — see aws-eks-tf/README.md for the `terraform state mv` commands.
