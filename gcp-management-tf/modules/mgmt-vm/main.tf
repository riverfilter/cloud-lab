data "google_compute_image" "debian" {
  family  = var.image_family
  project = var.image_project
}

resource "google_compute_instance" "mgmt" {
  project      = var.project_id
  zone         = var.zone
  name         = "${var.name_prefix}-vm"
  machine_type = var.machine_type

  # Tag the VM so the IAP-SSH firewall rule applies.
  tags = ["${var.name_prefix}-vm"]

  labels = var.labels

  boot_disk {
    initialize_params {
      image  = data.google_compute_image.debian.self_link
      size   = var.disk_size_gb
      type   = var.disk_type
      labels = var.labels
    }
  }

  network_interface {
    network    = var.network_self_link
    subnetwork = var.subnet_self_link

    # Ephemeral external IP only when explicitly opted in. Even then, the
    # firewall is locked to IAP CIDR.
    dynamic "access_config" {
      for_each = var.allow_public_ip ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  service_account {
    email  = var.service_account
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = var.enable_secure_boot
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  confidential_instance_config {
    enable_confidential_compute = var.enable_confidential
  }

  # OS Login is enforced at the metadata level. block-project-ssh-keys
  # belt-and-braces prevents a stray project-level SSH key from bypassing
  # IAM-based SSH.
  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = var.startup_script
  }

  # Graceful shutdown so Docker/kubectl sessions can drain.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = var.enable_confidential ? "TERMINATE" : "MIGRATE"
    preemptible         = false
  }

  allow_stopping_for_update = true

  # Re-applying a new startup script should trigger an in-place update,
  # not force-replace the instance.
  lifecycle {
    ignore_changes = [
      # GCP sometimes rewrites this under the hood; ignore to avoid churn.
      metadata["ssh-keys"],
    ]
  }
}
