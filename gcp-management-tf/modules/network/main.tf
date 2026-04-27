############################################
# VPC + subnet
############################################

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-subnet-${var.region}"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  # VPC flow logs on — cheap insurance for an IAP-only jump box; sampling
  # kept low to keep spend trivial.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

############################################
# Cloud NAT so the VM (no public IP) can reach the internet
# for apt, docker pulls, github, gcr, etc.
#
# The NAT IP is reserved as a static external address so that the egress
# IP is stable across NAT rebuilds. This is load-bearing: operators paste
# "<nat_public_ip>/32" into each cluster stack's authorized_cidrs tfvar
# (gcp-gke-tf, aws-eks-tf, azure-aks-tf) so the mgmt VM can reach the
# control planes. An AUTO_ONLY NAT IP would churn on rebuild and silently
# lock the mgmt VM out of every cluster.
############################################

resource "google_compute_address" "nat" {
  project      = var.project_id
  name         = "${var.name_prefix}-nat-ip"
  region       = var.region
  address_type = "EXTERNAL"
}

resource "google_compute_router" "nat" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.this.id
}

# NOTE: switching nat_ip_allocate_option from AUTO_ONLY to MANUAL_ONLY on
# an already-deployed NAT forces replacement of the google_compute_router_nat.
# That drops the current auto-allocated egress IP immediately and re-issues
# as the static google_compute_address.nat above. For this lab (intermittent
# clusters, destroy/re-apply is normal) that is acceptable; in a long-lived
# environment you would reserve the static IP first, import it onto the
# existing NAT, or plan a maintenance window.
resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

############################################
# Firewall: SSH from IAP CIDR only.
#
# 35.235.240.0/20 is Google's fixed IAP TCP forwarding range. Locking
# ingress to this CIDR means even if allow_public_ip is flipped on, the
# VM is not reachable from arbitrary internet sources — the client must
# tunnel through IAP and satisfy IAP IAM policy.
############################################

resource "google_compute_firewall" "iap_ssh" {
  project   = var.project_id
  name      = "${var.name_prefix}-allow-iap-ssh"
  network   = google_compute_network.this.name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Explicit deny-all ingress catches misconfigured "default" fallbacks.
# Lower priority than the IAP allow, higher than any implicit rule.
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.project_id
  name      = "${var.name_prefix}-deny-all-ingress"
  network   = google_compute_network.this.name
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}
