provider "azurerm" {
  # subscription_id is required on azurerm 4.x even when using az-login auth.
  # Passing it through a variable (rather than ARM_SUBSCRIPTION_ID env) makes
  # the target subscription an explicit, reviewable input to every apply.
  subscription_id = var.subscription_id

  # Tenant + client auth deliberately not set here. The provider walks the
  # standard Azure credential chain (az login / Managed Identity / OIDC
  # federation from CI) wherever the apply actually runs. Keeping client_id
  # and client_secret out of the stack is the no-long-lived-keys posture.

  features {
    # Azure-specific: azurerm requires this block even if empty. Defaults are
    # fine for a lab; notable tuning points for later:
    #   resource_group { prevent_deletion_if_contains_resources = true }
    #   key_vault      { purge_soft_delete_on_destroy           = true }
    # Neither is load-bearing here (no Key Vault, RG is dedicated).
  }
}

# azuread inherits tenant + auth from the same azure-cli / managed-identity /
# OIDC credential chain as azurerm. No explicit configuration needed — and
# deliberately none provided, to keep tenant/client secrets out of the stack.
# Only consumed when var.mgmt_vm_gcp_sa_unique_id is set (item 1 of the
# project roadmap: cross-cloud federated identity).
provider "azuread" {
  # Pin tenant to the same one azurerm resolved, so the AAD App and federated
  # credential never land in an operator's home tenant when it differs from
  # the AKS subscription's tenant. data source is declared in iam.tf.
  tenant_id = data.azurerm_client_config.current.tenant_id
}
