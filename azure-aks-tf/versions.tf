terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    # azuread is intentionally omitted. Admin group membership is supplied by
    # the operator via admin_group_object_ids, so no AAD lookups are needed
    # at plan time — one less provider, one less set of permissions to
    # pre-grant on the apply principal.
  }
}
