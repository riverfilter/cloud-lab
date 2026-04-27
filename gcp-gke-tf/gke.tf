resource "google_container_cluster" "this" {
  provider = google-beta

  name     = var.cluster_name
  location = var.zone # Zonal control plane: ~$0.10/hr vs regional ~$0.30/hr. Lab can tolerate single-zone control plane downtime.

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "${var.cluster_name}-pods"
    services_secondary_range_name = "${var.cluster_name}-services"
  }

  # Dataplane V2 (eBPF) is free and includes network policy enforcement. Leaving
  # enforcement ON is desirable here because the lab will host intentionally
  # vulnerable pods — cheap defense-in-depth. Host-privileged EDR DaemonSets
  # typically run with hostNetwork/privileged and are unaffected by pod-level
  # NetworkPolicies, so this does not conflict with an agent install.
  datapath_provider        = "ADVANCED_DATAPATH"
  enable_l4_ilb_subsetting = false

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Public control plane endpoint retained so kubectl works from authorized_cidrs.
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    master_global_access_config {
      enabled = false
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # GKE cost allocation surfaces per-namespace spend in billing exports — cheap
  # and useful when the lab grows a few more workloads.
  cost_management_config {
    enabled = true
  }

  resource_labels = var.labels

  # Disable add-ons not needed in a tiny lab. HTTP load balancing stays on because
  # it's free unless you create an Ingress of that class.
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    network_policy_config {
      # With Dataplane V2, this legacy Calico add-on must be disabled.
      disabled = true
    }
    dns_cache_config {
      enabled = false
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  # Small maintenance window; keeps auto-upgrades predictable.
  maintenance_policy {
    recurring_window {
      start_time = "2025-01-01T06:00:00Z"
      end_time   = "2025-01-01T10:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }

  lifecycle {
    ignore_changes = [
      # GKE rewrites initial_node_count on the removed default pool; ignore churn.
      initial_node_count,
    ]
  }
}

# Machine type rationale: e2-small (2 vCPU burstable, 2 GiB RAM).
# - e2-micro (1 GiB) is too tight: kubelet+system pods consume ~0.7 GiB, leaving
#   <300 MiB, which a typical EDR DaemonSet (often 512 Mi–1 GiB) can exhaust.
# - e2-medium (4 GiB) costs ~2x with no gain for a handful of lab pods.
# e2-small on Spot is ~$3-4/mo list and comfortably fits an EDR agent + a few
# lightweight vulnerable pods. Upgrade to e2-medium only if kubectl shows
# MemoryPressure or the agent CrashLoopBackOffs with OOMKilled.
resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-primary"
  cluster  = google_container_cluster.this.id
  location = var.zone

  node_count = var.node_count

  # Autoscaling intentionally omitted: lab has a fixed tiny footprint and a
  # surprise scale-up on a compromised pod would be expensive/noisy.

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 20
    disk_type    = "pd-standard"
    image_type   = "COS_CONTAINERD"

    spot = var.use_spot_vms

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    labels = var.labels

    tags = ["gke-node", "${var.cluster_name}-node"]
  }

  lifecycle {
    ignore_changes = [
      # GKE may auto-rotate node version within the REGULAR channel.
      node_config[0].kubelet_config,
      version,
    ]
  }
}
