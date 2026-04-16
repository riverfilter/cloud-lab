locals {
  # Computed names keep the cluster_name prefix consistent across every
  # resource in the stack, matching the GKE / EKS siblings.
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "${var.cluster_name}-rg"

  # AKS's DNS service IP must live inside service_cidr. Convention is the
  # tenth address, which leaves 1-9 for reserved uses. cidrhost produces the
  # address from the network + host offset.
  dns_service_ip = cidrhost(var.service_cidr, 10)
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}

# Dedicated VNet for the cluster. Not shared with anything else in the
# subscription — blast-radius isolation mirrors the GKE dedicated-VPC posture.
resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Single subnet for the node VMSS. With Azure CNI Overlay we do NOT need a
# separate pod subnet — pod IPs come from pod_cidr which is outside the VNet
# entirely, same shape as GKE secondary pod ranges. This both saves IPv4 and
# lets the VNet itself stay small (/16 is overkill today; /20 would do).
resource "azurerm_subnet" "nodes" {
  name                 = "${var.cluster_name}-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.nodes_subnet_cidr]
}

# NSG on the node subnet. AKS manages its own rules on the VMSS NICs, but an
# explicit deny-all-inbound at the subnet edge is belt-and-braces for a lab
# that will host deliberately vulnerable pods. We do not add any allow rules
# here — AKS needs no inbound from the internet; egress (the direction nodes
# actually initiate) is governed by VNet routes + NAT Gateway, not by NSG.
resource "azurerm_network_security_group" "nodes" {
  name                = "${var.cluster_name}-nodes-nsg"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  # Default NSG rules already deny all inbound from Internet and allow
  # intra-VNet + LB probes. We add an explicit, higher-priority deny for
  # Internet-sourced traffic as a documented declaration of intent — even
  # though the default rule expresses the same policy, an explicit rule is
  # harder to accidentally override when someone later adds an allow.
  security_rule {
    name                       = "DenyInboundFromInternet"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

# ----------------------------------------------------------------------------
# Egress: NAT Gateway attached to the node subnet.
#
# AKS's default outbound_type is "loadBalancer", which uses a public Standard
# LB's outbound rules for SNAT. That path works but bills per-rule and
# per-data-processed, and its SNAT port exhaustion behaviour is notoriously
# hard to diagnose under load.
#
# userAssignedNATGateway is a cleaner model for a small footprint:
#   - ~$32/mo fixed + $0.045/GB processed, predictable
#   - 64,512 SNAT ports per public IP attached, vs ~1k/VM on LB outbound
#   - No dependency on an AKS-managed public LB for egress
# The tradeoff is a fixed $32/mo floor vs the LB path's near-zero idle cost,
# but for any cluster that sustains real egress the NAT Gateway ends up
# cheaper and far more predictable. Same call made in the EKS stack.
# ----------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "${var.cluster_name}-nat-pip"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard" # NAT Gateway requires Standard SKU + Static allocation.
  zones               = ["1"]      # Zonal NAT matches the zonal control plane posture of GKE.
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${var.cluster_name}-nat"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  zones                   = ["1"]
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "nodes" {
  subnet_id      = azurerm_subnet.nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ----------------------------------------------------------------------------
# Optional: Log Analytics workspace for AKS diagnostic settings.
# Off by default (enable_diagnostics). Log Analytics ingestion is ~$2.30/GB
# in East US and AKS audit log volume on an idle cluster is still non-zero;
# leave this off until actively investigating something.
# ----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  count = var.enable_diagnostics ? 1 : 0

  name                = "${var.cluster_name}-logs"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = var.diagnostics_retention_days
  tags                = var.tags
}
