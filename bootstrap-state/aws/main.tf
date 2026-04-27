# Bootstrap S3 bucket + KMS key for Terraform remote state across every
# cloud-lab AWS stack.
#
# Self-bootstrapping: local state in-tree, because this stack owns the
# bucket every other stack will use.
#
# Locking: Terraform 1.10+ supports S3-native lockfile locking
# (`use_lockfile = true` in the backend config), which obsoletes the
# DynamoDB lock table pattern. The aws-eks-tf stack pins terraform
# >= 1.5.0, but since the operator drives `init -migrate-state` on whatever
# their workstation has installed, and required_version gates the apply
# host, bumping to 1.10+ at init time is acceptable for a lab. The
# backend snippet emitted below therefore omits DynamoDB. If an operator
# has a hard pin < 1.10, they can add `aws_dynamodb_table.tfstate_locks`
# back in-tree and switch the snippet to use `dynamodb_table` — left as a
# README note rather than code to avoid shipping dead resources.

########################################
# KMS key for state-at-rest encryption
########################################

# Used by aws_kms_key_policy.tfstate below to grant the operator principal
# (the `aws sts get-caller-identity` ARN of the human / role running this
# apply) the four KMS data-plane actions S3 needs at state read/write time.
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "tfstate" {
  description             = "Encryption for cloud-lab Terraform state"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # Guard against accidental destroy that would strand all sibling-stack state.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/cloud-lab-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# Explicit key policy. The default AWS-managed CMK policy grants only the
# account root principal kms:* — it does NOT grant the calling IAM
# principal data-plane actions (Encrypt/Decrypt/GenerateDataKey/
# DescribeKey). An operator scoped down from AdministratorAccess (the
# stated least-privilege posture) hits AccessDenied on GenerateDataKey at
# the first state write. The explicit policy below preserves the root
# admin grant AND grants the apply-time caller the four actions they need.
#
# Note: aws_kms_key_policy applies retroactively — re-applying this
# bootstrap on an existing key replaces whatever policy was on it.
resource "aws_kms_key_policy" "tfstate" {
  key_id = aws_kms_key.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "OperatorStateAccess"
        Effect    = "Allow"
        Principal = { AWS = data.aws_caller_identity.current.arn }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })
}

########################################
# S3 bucket for tfstate
########################################

resource "aws_s3_bucket" "tfstate" {
  # Bucket names are a global namespace; the prefix variable is the
  # uniqueness guard. `-cloud-lab-tfstate` suffix keeps the name
  # self-documenting in Cost Explorer / CloudTrail.
  bucket = "${var.bucket_name_prefix}-cloud-lab-tfstate"

  # Guard against accidental destroy that would strand all sibling-stack state.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      # aws:kms (not aws:kms:dsse) with a CMK gives us auditable KMS grants
      # via CloudTrail. bucket_key_enabled = true cuts KMS Decrypt requests
      # ~99% — material cost control on a bucket Terraform reads on every
      # plan.
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Forever-versioning would accrete storage without upside for a lab;
  # 90 days is plenty of time to notice a bad apply and roll back.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # AWS now requires an explicit filter (even an empty one) on lifecycle
    # rules that do not scope by prefix/tag.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Abort lingering multipart uploads — cheap hygiene. Terraform state
    # objects are tiny, so this is belt-and-braces for any future writer.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
