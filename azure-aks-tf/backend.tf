# Remote state backend.
#
# Activate in two steps:
#   1. Apply ../bootstrap-state/azure — see that stack's README for details.
#   2. Uncomment the block below, then run
#        terraform init -backend-config=backend.hcl -migrate-state
#      Pass resource_group_name / storage_account_name / container_name /
#      key via backend.hcl (copy from backend.hcl.example) rather than
#      hardcoding here, so this file stays environment-agnostic.
#
# `use_azuread_auth = true` is required because the bootstrap disables
# shared-access keys on the storage account (AAD-only, matching the AKS
# stack's local_account_disabled posture).
#
# azurerm backend uses native blob-lease locking — no sidecar required.
#
# terraform {
#   backend "azurerm" {}
# }
