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
