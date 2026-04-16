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
