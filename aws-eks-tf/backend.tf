# Remote state backend.
#
# Activate in two steps:
#   1. Apply ../bootstrap-state/aws — see that stack's README for details.
#   2. Uncomment the block below, then run
#        terraform init -backend-config=backend.hcl -migrate-state
#      Pass bucket / region / kms_key_id / key via backend.hcl (copy from
#      backend.hcl.example) rather than hardcoding here, so this file
#      stays environment-agnostic.
#
# Locking: the backend snippet uses `use_lockfile = true` — S3-native
# conditional-write locking, available in Terraform 1.10+. Replaces the
# historical DynamoDB lock table. If your operator pin is < 1.10, drop
# `use_lockfile` and add `dynamodb_table = "..."` after creating an
# aws_dynamodb_table alongside the bucket.
#
# terraform {
#   backend "s3" {}
# }
