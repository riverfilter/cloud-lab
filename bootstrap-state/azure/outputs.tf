output "resource_group_name" {
  description = "Resource group that holds the tfstate storage account."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Storage account that holds the tfstate container."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Blob container that holds tfstate blobs."
  value       = azurerm_storage_container.tfstate.name
}

output "container_resource_id" {
  description = "Resource Manager ID of the tfstate container — use as the scope when granting an external principal access out-of-band."
  # Explicit ARM-ID interpolation. azurerm_storage_container.resource_manager_id
  # is deprecated in azurerm ~> 4.14; the data-plane .id attribute returns the
  # blob URL, not the ARM resource ID, so it cannot be a drop-in replacement.
  # The interpolation below is byte-identical to what resource_manager_id
  # emitted under the hood.
  value = "${azurerm_storage_account.tfstate.id}/blobServices/default/containers/${azurerm_storage_container.tfstate.name}"
}

output "backend_snippet" {
  description = "Drop-in backend block for each sibling Azure stack's backend.tf. Replace <stack-name>/<env> with e.g. `azure-aks-tf/sec-lab`. `use_azuread_auth = true` is required because shared_access_key_enabled = false on the storage account."
  value       = <<-EOT
    terraform {
      backend "azurerm" {
        resource_group_name  = "${azurerm_resource_group.tfstate.name}"
        storage_account_name = "${azurerm_storage_account.tfstate.name}"
        container_name       = "${azurerm_storage_container.tfstate.name}"
        key                  = "<stack-name>/<env>.tfstate"
        use_azuread_auth     = true
      }
    }
  EOT
}
