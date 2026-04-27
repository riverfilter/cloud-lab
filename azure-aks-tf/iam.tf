# User-assigned managed identity for the AKS control plane.
#
# SystemAssigned would be simpler, but a UserAssigned identity lets us
# create the role assignment (Network Contributor on the node subnet)
# BEFORE the cluster exists, sidestepping the classic AKS chicken-and-egg
# where the system-assigned principal ID isn't known until after the
# cluster has tried and failed to reconcile the VNet.
#
# Keeping the identity as a separate resource also means destroying and
# recreating the cluster does not churn its role assignments — the
# identity (and its bindings) outlive a cluster rebuild.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

# Scope the cluster identity tightly. With userAssignedNATGateway as the
# outbound type AND a pre-created subnet + NSG, the cluster identity only
# needs Network Contributor on the subnet itself — NOT on the VNet. This
# is narrower than the typical AKS + BYO-VNet guidance which suggests
# Network Contributor at VNet scope.
#
# Why this scope works:
#   - AKS manages VMSS NIC assignments within the subnet (needs NC on subnet)
#   - NAT Gateway is already associated; AKS does not need to mutate it
#   - NSG is pre-associated to the subnet; AKS does not own it
#   - Route table is managed by Azure for the NAT path; AKS does not edit it
# If you later switch outbound_type to "loadBalancer", you'll need NC on the
# whole VNet so AKS can create the outbound LB + its public IP.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# No Kubernetes-side RBAC roles in this file. AAD integration with
# azure_rbac_enabled = true (see aks.tf) means Kubernetes authorization is
# driven by Azure role assignments scoped at cluster/namespace, with admin
# group membership supplied as admin_group_object_ids.
#
# If you need to wire ACR for image pulls, uncomment below. The kubelet
# identity (not the cluster identity) is what actually pulls images, and
# AKS auto-creates it as a second user-assigned identity inside the node
# resource group. Reference via azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id.
#
# resource "azurerm_role_assignment" "kubelet_acrpull" {
#   scope                = data.azurerm_container_registry.acr.id
#   role_definition_name = "AcrPull"
#   principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
# }

# ---------------------------------------------------------------------------
# Cross-cloud federated identity for the mgmt VM (GCP -> AAD WIF).
#
# The mgmt VM running on GCP signs a JWT with its attached GCP SA, AAD
# validates it against the federated credential on the AAD App below and
# issues an AAD access token. `kubelogin` converts this into an AKS
# kubeconfig. No static AAD client secrets ever touch the VM.
#
# All resources in this block are count-gated on var.mgmt_vm_gcp_sa_unique_id
# being non-empty, so an apply without the variable set is a clean no-op and
# requires no azuread permissions on the apply principal.
# ---------------------------------------------------------------------------

# Current tenant_id used by the azurerm provider. Needed as an output so the
# mgmt VM can point `az login --federated-token` and kubelogin at the right
# tenant without the operator having to look it up.
data "azurerm_client_config" "current" {}

resource "azuread_application" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  display_name = "${var.cluster_name}-mgmt-vm"
}

resource "azuread_service_principal" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  # azuread 3.x: `client_id` replaces the older `application_id` argument.
  client_id = azuread_application.mgmt_vm[0].client_id
}

# Federated credential that trusts Google's OIDC issuer. Both subject AND
# audience are pinned: subject = GCP SA unique_id (not email — emails can be
# reassigned), audience = the fixed AAD token-exchange string.
resource "azuread_application_federated_identity_credential" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  # azuread 3.x wants the application's resource ID (the "/applications/<uuid>"
  # form returned by .id), NOT the client_id or object_id.
  application_id = azuread_application.mgmt_vm[0].id
  display_name   = "gcp-mgmt-vm"
  description    = "Trusts the GCP mgmt VM SA (by numeric unique_id) to mint AAD tokens for this app."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://accounts.google.com"
  subject        = var.mgmt_vm_gcp_sa_unique_id
}

# Azure RBAC for Kubernetes: cluster-admin on THIS cluster only. Matches the
# AWS side's AmazonEKSClusterAdminPolicy scope=cluster. Namespace-scoped
# roles would defeat the purpose — the mgmt VM is the lab's single kubectl
# entry point.
resource "azurerm_role_assignment" "mgmt_vm_aks_admin" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_service_principal.mgmt_vm[0].object_id
}
