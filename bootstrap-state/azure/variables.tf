variable "subscription_id" {
  description = "Azure subscription ID (GUID) that will own the tfstate resource group and storage account. Explicit rather than ARM_SUBSCRIPTION_ID env so it is reviewable in every plan."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription GUID."
  }
}

variable "location" {
  description = "Azure region for the resource group + storage account. Matches azure-aks-tf's default so the bucket lives next to the clusters it holds state for."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group that will hold the tfstate storage account. Dedicated RG so lifecycle is distinct from any cluster stack."
  type        = string
  default     = "cloud-lab-tfstate-rg"
}

variable "storage_account_name" {
  description = "Globally-unique storage account name (3-24 chars, lowercase alphanumeric). Azure storage account names are a global namespace — pick something tied to your subscription (e.g. `<alias>lab<rand>`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters (no hyphens — Azure storage account naming rules)."
  }
}

variable "container_name" {
  description = "Name of the blob container that holds tfstate."
  type        = string
  default     = "tfstate"
}

variable "operator_principal_id" {
  description = "Optional AAD principal (user or group) object ID to grant `Storage Blob Data Contributor` on the container. When empty, no role assignment is created — the operator must grant the role out-of-band (e.g. via Portal) before `terraform init -migrate-state`. Required because shared_access_key_enabled = false forces AAD auth for blob writes."
  type        = string
  default     = ""

  validation {
    condition     = var.operator_principal_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.operator_principal_id))
    error_message = "operator_principal_id must be empty or an AAD object GUID."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    environment = "shared"
    service     = "tfstate"
    managed-by  = "terraform"
  }
}
