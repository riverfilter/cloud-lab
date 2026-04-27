terraform {
  # Floor bumped to 1.10 to match aws-eks-tf — the bootstrap itself does
  # not require 1.10 features, but homogenising the floor stops an
  # operator from apply-ing this stack on 1.9 and then discovering at
  # `init -migrate-state` time that the sibling backend snippet
  # (`use_lockfile = true`, S3-native locking) is unsupported.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Matches aws-eks-tf/versions.tf. AWS provider 5.80+ supports the S3
      # resources used below (bucket_versioning, sse config, public access
      # block, lifecycle config) with the split-resource schema.
      version = "~> 5.80"
    }
  }
}
