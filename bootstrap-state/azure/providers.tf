provider "azurerm" {
  # subscription_id is required on azurerm 4.x even when using az-login auth.
  # Passing it through a variable (rather than ARM_SUBSCRIPTION_ID env) makes
  # the target subscription an explicit, reviewable input to every apply.
  subscription_id = var.subscription_id

  features {}
}
