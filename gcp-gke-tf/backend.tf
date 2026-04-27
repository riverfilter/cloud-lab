# Remote state backend.
#
# Activate in two steps:
#   1. Apply ../bootstrap-state/gcp — see that stack's README for details.
#   2. Uncomment the block below, then run
#        terraform init -backend-config=backend.hcl -migrate-state
#      Pass bucket + prefix via backend.hcl (copy from backend.hcl.example)
#      rather than hardcoding here, so this file stays environment-agnostic.
#
# GCS backends lock natively via the generation-checked lock object; no
# DynamoDB-equivalent sidecar is required.
#
# terraform {
#   backend "gcs" {}
# }
