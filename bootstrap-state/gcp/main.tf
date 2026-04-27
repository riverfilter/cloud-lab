# Bootstrap bucket for Terraform remote state across every cloud-lab GCP stack.
#
# This stack is self-bootstrapping: it manages the bucket that will hold
# remote state for every *other* stack, so this stack itself keeps local
# state (terraform.tfstate alongside this .tf file). Commit-in-tree is
# acceptable because the only resource here is the bucket record — no
# secrets, no cluster credentials.
#
# GCS-backed Terraform backends use the object's generation metadata and an
# advisory lock object for mutual exclusion; no sidecar lock primitive
# (DynamoDB-equivalent) is required.

resource "google_storage_bucket" "tfstate" {
  # GCS bucket names are globally unique. Prefixing with project_id is the
  # idiomatic uniqueness guard and keeps the name self-documenting.
  name     = "${var.project_id}-cloud-lab-tfstate"
  location = var.region

  # force_destroy = false means `terraform destroy` on this stack will fail
  # if any objects (i.e. any remote state) still exist. That is the correct
  # posture — destruction of the state bucket should be deliberate and
  # manual, after every consumer stack has been migrated off.
  force_destroy = false

  # UBLA + public-access-prevention eliminate the two historical footguns of
  # GCS: per-object ACLs that can drift from bucket IAM, and accidental
  # allUsers / allAuthenticatedUsers bindings.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Versioning is load-bearing for tfstate recovery. If `terraform apply`
  # corrupts state (rare but catastrophic), rollback to a prior generation
  # restores the stack without re-importing every resource.
  versioning {
    enabled = true
  }

  # Cap version history to bound storage cost — for a lab with infrequent
  # applies, 10 noncurrent versions is ~weeks of headroom while keeping the
  # bucket bill measured in cents.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels

  # Guard against accidental destroy that would strand all sibling-stack state.
  lifecycle {
    prevent_destroy = true
  }
}
