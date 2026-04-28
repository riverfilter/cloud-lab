resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  # DNS prefix is part of the public FQDN: <prefix>-<hash>.hcp.<region>.azmk8s.io.
  # Derived from the cluster name so operators can guess it without looking it up.
  dns_prefix = var.cluster_name

  kubernetes_version = var.kubernetes_version
  sku_tier           = var.sku_tier

  # Name the node resource group explicitly. AKS auto-creates an "MC_<rg>_<cluster>_<loc>"
  # RG to hold the VMSS, managed LB, NSG, and route table; pinning its name
  # makes cleanup scripts and cost reports easier to write.
  node_resource_group = "${local.resource_group_name}-nodes"

  # Force AAD-backed Kubernetes auth. With local_account_disabled = true, the
  # --admin kubeconfig (which contains a long-lived static token) is not
  # issuable — every kubectl call must come through AAD + the group
  # membership declared in admin_group_object_ids. Safer posture for a lab
  # with intentionally vulnerable workloads, at the cost of losing the
  # break-glass kubeconfig. Parameterized if you need it flipped off.
  local_account_disabled = var.local_account_disabled

  # OIDC issuer + Workload Identity are the AKS equivalents of GKE Workload
  # Identity / EKS IRSA. Together they let pods get federated tokens for
  # AAD-protected resources without the node-level SP credentials.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Use the pre-created user-assigned identity for the control plane. See
  # iam.tf for the rationale.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  # Azure RBAC for Kubernetes replaces the legacy "azure-aad-rbac + K8s RBAC"
  # split. With azure_rbac_enabled = true, Kubernetes authorization is
  # performed against Azure role assignments — so `kubectl get pods` requires
  # "Azure Kubernetes Service RBAC Reader" (or similar) on the cluster.
  # admin_group_object_ids auto-grants cluster-admin-equivalent to the listed
  # AAD groups, which is how the operator kubectls in after apply.
  azure_active_directory_role_based_access_control {
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
    tenant_id              = null # defaults to the provider's tenant (same subscription)
  }

  # Restricted public API server endpoint. Mirrors the GKE master_authorized_networks
  # posture: public FQDN stays reachable but only from the operator's CIDRs.
  # 0.0.0.0/0 is rejected at variable validation.
  #
  # Private cluster (private_cluster_enabled = true) is explicitly NOT used
  # here. A private control plane requires either a jumpbox inside the VNet
  # or a Private Endpoint DNS forwarder, neither of which exists in this
  # stack yet. That's a roadmap item; see roadmap.md.
  api_server_access_profile {
    authorized_ip_ranges = var.authorized_cidrs
  }

  # Network profile: Azure CNI Overlay + Cilium dataplane.
  #
  # Azure CNI Overlay (network_plugin_mode = "overlay") allocates pod IPs
  # from pod_cidr — a range OUTSIDE the VNet — and encapsulates in VXLAN
  # between nodes. This is the closest analog to GKE's secondary-range pod
  # IP model and sidesteps the classic Azure CNI problem where every pod
  # consumes a VNet IP.
  #
  # Cilium (network_data_plane = "cilium", network_policy = "cilium") is the
  # eBPF dataplane. It is free on AKS, enforces Kubernetes NetworkPolicy,
  # and is the AKS equivalent of GKE Dataplane V2. Mandatory for a lab with
  # deliberately vulnerable workloads — cheap defense-in-depth via
  # NetworkPolicy resources.
  #
  # outbound_type = "userAssignedNATGateway" wires the NAT Gateway created
  # in network.tf as the egress path; AKS will not create its own outbound LB.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = local.dns_service_ip
  }

  # --------------------------------------------------------------------------
  # Default (system) node pool.
  #
  # AKS requires exactly one "system" node pool at cluster creation, which
  # hosts kube-system pods (coredns, metrics-server, konnectivity, etc). It
  # cannot be Spot — that's the reason this stack defaults use_spot_vms=false
  # and keeps a single-pool topology instead of spinning up a second Spot
  # user pool just to save a few dollars on worker VMs.
  #
  # VM size rationale — Standard_B2s (2 vCPU burstable, 4 GiB):
  #   - B1s (1 GiB) / B1ms (2 GiB): system pods + kubelet already consume
  #     most of that; a typical EDR agent (~512 Mi–1 GiB) will OOM on B1s.
  #   - B2s (4 GiB): comfortable fit for an EDR agent + a handful of lab
  #     pods. 2 GiB more RAM than GCP e2-small, which is a plus on Azure
  #     where system pod overhead is slightly higher (CSI driver, CNI, etc).
  #   - D2ads_v5 (2 vCPU / 8 GiB, non-burstable): ~1.7x cost; use only if
  #     kubectl shows sustained CPU throttle on B2s.
  # Burstable credits are usually fine for lab-scale workloads — bursty
  # compilation + docker pull traffic is exactly the pattern B-series is for.
  #
  # Ephemeral OS disk would be faster but requires the VM SKU's cache size
  # to fit the OS disk; B2s has ~8 GiB temp + cache which is too small for
  # a 30 GiB ephemeral disk. So: Managed Premium_LRS 30 GiB. Document.
  #
  # Autoscaling intentionally omitted, matching GKE/EKS rationale: fixed
  # footprint + a surprise scale-up on a compromised pod would be expensive
  # and noisy.
  # --------------------------------------------------------------------------
  default_node_pool {
    name    = "system"
    vm_size = var.node_vm_size

    # Keep this pool available for regular workloads too. Setting
    # only_critical_addons_enabled = true would taint the pool with
    # CriticalAddonsOnly:NoSchedule and require Spot pool workloads to add
    # tolerations. Not what we want for a single-pool lab.
    only_critical_addons_enabled = false

    node_count           = var.node_count
    orchestrator_version = var.kubernetes_version

    os_disk_size_gb = var.node_disk_size_gb
    os_disk_type    = "Managed" # Ephemeral would require larger cache; see comment above.
    os_sku          = "Ubuntu"

    # Private nodes: VMSS instances get no public IP. Egress goes via the
    # NAT Gateway attached to the subnet.
    node_public_ip_enabled = false

    vnet_subnet_id = azurerm_subnet.nodes.id

    # host_encryption_enabled requires the subscription to have the
    # Microsoft.Compute/EncryptionAtHost feature registered; not enabled
    # here to keep the stack applyable from a fresh subscription. Roadmap item.

    upgrade_settings {
      max_surge = "10%"
    }

    tags = var.tags

    # node_labels are Kubernetes node labels (visible to the scheduler /
    # nodeSelector / nodeAffinity). var.tags is an Azure resource-tag map
    # and intentionally does NOT flow in here — leaking arbitrary tag
    # semantics into scheduler-visible labels would surface as label-based
    # scheduling decisions on operator-provided tag values.
    node_labels = {
      "lab.purpose" = "security-research"
    }
  }

  # Azure KeyVault KMS etcd encryption intentionally skipped. Adds a Key Vault
  # dependency (HSM, access policy, CMK rotation) that complicates destroy
  # and is overkill for a lab. Roadmap item.

  # monitor_metrics (Azure Monitor managed Prometheus) — default off.
  # Billed per metric-sample; cheap to re-enable later.
  dynamic "monitor_metrics" {
    for_each = var.enable_monitor_metrics ? [1] : []
    content {
      # Empty block enables with AKS defaults. Explicit filters can be added
      # if someone is trying to shrink cardinality.
    }
  }

  tags = var.tags

  depends_on = [
    # Network Contributor on the subnet must exist before AKS reconciles,
    # or the first apply races and fails with a permissions error on VMSS
    # NIC creation.
    azurerm_role_assignment.cluster_network_contributor,
    azurerm_subnet_nat_gateway_association.nodes,
    azurerm_subnet_network_security_group_association.nodes,
  ]

  lifecycle {
    ignore_changes = [
      # AKS auto-rolls node image and patch version within the chosen minor.
      # Ignoring kubernetes_version here prevents every plan-after-patch from
      # showing drift; operators bump var.kubernetes_version deliberately when
      # they want a minor-version change.
      #
      # node_count is deliberately NOT ignored: autoscaling is disabled in
      # this stack, so var.node_count is the single source of truth. An
      # earlier version of this file ignored default_node_pool[0].node_count
      # which silently dropped resize requests on apply.
      kubernetes_version,
    ]
  }
}

# Diagnostic settings to the Log Analytics workspace. Mirrors the GKE
# SYSTEM_COMPONENTS + WORKLOADS logging posture (kube-apiserver + kube-audit
# are the two that actually matter for security research). Off by default
# because Log Analytics ingest charges dominate lab cost at any non-trivial
# audit volume.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "${var.cluster_name}-diag"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-audit"
  }

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# --------------------------------------------------------------------------
# Optional Spot user node pool.
#
# AKS system pool cannot be Spot; when use_spot_vms = true, the system pool
# above stays at 1 on-demand node (bare minimum for kube-system) and lab
# workloads target this pool via nodeSelector / tolerations. The pool is
# tainted with kubernetes.azure.com/scalesetpriority=spot:NoSchedule by
# default (Azure's built-in Spot taint), so every workload that wants to
# run here must opt in.
#
# Cost tradeoff: adding this pool DOUBLES the on-demand VM floor (system
# pool stays at 1 B2s @ ~$30/mo PLUS this pool's Spot VMs). It's cheaper
# than 2x on-demand only if your Spot pool node count meaningfully exceeds
# the system pool. For small labs the default use_spot_vms=false is typically
# cheaper and simpler.
# --------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.use_spot_vms ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id

  vm_size              = var.spot_node_vm_size
  node_count           = var.spot_node_count
  orchestrator_version = var.kubernetes_version

  os_disk_size_gb = var.node_disk_size_gb
  os_disk_type    = "Managed"
  os_sku          = "Ubuntu"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # -1 = pay up to the on-demand price (same behaviour as GKE Spot).

  node_public_ip_enabled = false
  vnet_subnet_id         = azurerm_subnet.nodes.id

  # node_labels are Kubernetes node labels (visible to the scheduler /
  # nodeSelector / nodeAffinity). var.tags is an Azure resource-tag map
  # and intentionally does NOT flow in here — leaking arbitrary tag
  # semantics into scheduler-visible labels would surface as label-based
  # scheduling decisions on operator-provided tag values.
  node_labels = {
    "lab.purpose"                           = "security-research"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  tags = var.tags
}
