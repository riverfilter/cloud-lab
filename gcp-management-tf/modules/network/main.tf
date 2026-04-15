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
############################################

resource "google_compute_router" "nat" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
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
