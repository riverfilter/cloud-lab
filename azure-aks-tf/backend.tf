// Remote state backend.
//
// Uncomment and fill in once a Storage Account + container exist. The storage
// account MUST have blob versioning + soft delete enabled; prefer a
// customer-managed key (CMK) in Key Vault if this subscription is subject
// to compliance controls.
//
// Create the backend resources out-of-band (chicken-and-egg with
// Terraform-managed state):
//
//   az group create --name tfstate-rg --location eastus
//   az storage account create --name <globally-unique-name> \
//     --resource-group tfstate-rg --location eastus --sku Standard_LRS \
//     --encryption-services blob --min-tls-version TLS1_2 \
//     --allow-blob-public-access false
//   az storage account blob-service-properties update \
//     --account-name <name> --resource-group tfstate-rg \
//     --enable-versioning true
//   az storage container create --name tfstate \
//     --account-name <name> --auth-mode login
//
// AzureRM backend uses blob leases for state locking — no separate lock
// table needed (unlike S3+DynamoDB).
//
// terraform {
//   backend "azurerm" {
//     resource_group_name  = "REPLACE-ME-tfstate-rg"
//     storage_account_name = "REPLACEMEtfstatestorage"
//     container_name       = "tfstate"
//     key                  = "azure-aks-tf/sec-lab.tfstate"
//     use_azuread_auth     = true
//   }
// }
