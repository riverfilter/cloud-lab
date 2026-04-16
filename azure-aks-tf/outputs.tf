output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource group holding the cluster and its VNet/NAT/identity."
  value       = azurerm_resource_group.this.name
}

output "node_resource_group_name" {
  description = "AKS-managed node resource group (holds VMSS, managed LB, NSG, route table). Cost reports commonly key off this."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "location" {
  description = "Azure region the cluster lives in."
  value       = azurerm_resource_group.this.location
}

output "cluster_endpoint" {
  description = "AKS API server FQDN."
  value       = azurerm_kubernetes_cluster.this.fqdn
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded AKS cluster CA certificate."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for Workload Identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the auto-created kubelet user-assigned identity (the one to grant AcrPull on for ACR-backed image pulls)."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_identity_principal_id" {
  description = "Principal (object) ID of the user-assigned control-plane identity created by this stack."
  value       = azurerm_user_assigned_identity.cluster.principal_id
}

output "vnet_name" {
  description = "VNet name."
  value       = azurerm_virtual_network.this.name
}

output "nodes_subnet_name" {
  description = "Node subnet name."
  value       = azurerm_subnet.nodes.name
}

output "nat_gateway_public_ip" {
  description = "Public IP attached to the NAT Gateway — the egress source IP seen by external services (e.g. an EDR agent's management/ingest cloud)."
  value       = azurerm_public_ip.nat.ip_address
}

output "kubectl_configure_command" {
  description = "Run this to populate ~/.kube/config for the cluster. Uses AAD-backed auth because local_account_disabled is true by default."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}
