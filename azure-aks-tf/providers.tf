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
