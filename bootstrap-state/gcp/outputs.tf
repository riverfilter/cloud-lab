output "bucket_name" {
  description = "Name of the GCS bucket that holds remote state for every GCP sibling stack."
  value       = google_storage_bucket.tfstate.name
}

output "backend_snippet" {
  description = "Drop-in backend block for each sibling GCP stack's backend.tf. Replace <stack-name> with one of: gcp-management-tf, gcp-gke-tf."
  value       = <<-EOT
    terraform {
      backend "gcs" {
        bucket = "${google_storage_bucket.tfstate.name}"
        prefix = "<stack-name>"
      }
    }
  EOT
}
