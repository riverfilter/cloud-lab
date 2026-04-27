terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Matches azure-aks-tf/versions.tf.
      version = "~> 4.14"
    }
  }
}
