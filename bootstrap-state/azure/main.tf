# Bootstrap Resource Group + Storage Account + container for Terraform
# remote state across every cloud-lab Azure stack.
#
# Self-bootstrapping: local state in-tree, because this stack owns the
# container every other stack will use.
#
# Locking: azurerm backend uses native blob-lease locking. No sidecar
# lock primitive required.

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # Cheapest — tfstate is trivially re-creatable; no need for GRS.

  min_tls_version = "TLS1_2"

  # Force AAD auth end-to-end. This matches the AAD-only posture on the
  # AKS cluster stack (local_account_disabled = true there) and eliminates
  # the shared-key attack surface for anyone who later gains Reader on
  # the storage account.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false

  blob_properties {
    # Versioning is load-bearing for tfstate recovery. Bad applies (rare
    # but catastrophic) can be rolled back via prior blob versions.
    versioning_enabled = true

    # Soft-delete retention. Azure storage-account / container deletes
    # are irreversible after the retention window closes, and the default
    # subscription policy is not guaranteed to cover us. 30 days is
    # cheap insurance — at tfstate's tiny footprint the cost is rounding
    # error, and the recovery window comfortably outlasts a typical
    # mis-apply discovery cycle.
    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = var.tags

  # Guard against accidental destroy that would strand all sibling-stack state.
  # Azure is the most dangerous of the three clouds here: azurerm_storage_account
  # deletes happily even when the account is non-empty, taking every container
  # and blob with it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  # Guard against accidental destroy that would strand all sibling-stack state.
  lifecycle {
    prevent_destroy = true
  }
}

# Optional: grant the operator `Storage Blob Data Contributor` on the
# container. This is required because shared_access_key_enabled = false
# means plane-level keys cannot be used — Terraform's azurerm backend
# authenticates as the logged-in AAD principal and needs data-plane blob
# write permissions to create / lock / update state blobs.
#
# Count-gated so an operator who prefers to grant the role via Portal
# / `az role assignment create` does not need to feed a principal ID
# into tfvars.
resource "azurerm_role_assignment" "operator_blob_contributor" {
  count = var.operator_principal_id == "" ? 0 : 1

  scope                = azurerm_storage_container.tfstate.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.operator_principal_id
}
