variable "project_id" {
  description = "GCP project ID that will own the tfstate bucket. The project is also used as the uniqueness prefix for the globally-scoped bucket name."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must be set."
  }
}

variable "region" {
  description = "Region for the regional GCS bucket. Regional storage is ~20% cheaper than multi-region for a single-writer tfstate use case; matches gcp-management-tf's default."
  type        = string
  default     = "us-central1"
}

variable "labels" {
  description = "Labels applied to the bucket. Keys/values must match GCP label constraints (lowercase, <=63 chars)."
  type        = map(string)
  default = {
    environment = "shared"
    service     = "tfstate"
    managed-by  = "terraform"
  }
}
