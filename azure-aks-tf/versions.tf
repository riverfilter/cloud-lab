terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    # azuread is added for cross-cloud federated identity (item 1 of the
    # project roadmap). When var.mgmt_vm_gcp_sa_unique_id is empty, no
    # azuread resources are created — so the provider is pulled in for
    # plan-time schema only, and an apply with the feature disabled still
    # does not require any AAD permissions on the apply principal.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}
