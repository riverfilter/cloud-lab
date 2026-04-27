variable "region" {
  description = "AWS region for the S3 bucket, KMS key, and (if you choose to add one later) DynamoDB lock table. Matches aws-eks-tf's default so the bucket lives next to the clusters it holds state for."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name_prefix" {
  description = "Prefix for the globally-unique S3 bucket name. Final bucket is `<prefix>-cloud-lab-tfstate`. S3 bucket names are a global namespace, so the prefix is load-bearing — pick something tied to your account (e.g. the account alias, or `<yourname>-lab`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "bucket_name_prefix must be lowercase alphanumeric + hyphen, 3-50 chars, start/end alphanumeric (S3 bucket name rules)."
  }
}

variable "tags" {
  description = "Tags applied to every resource via the provider's default_tags."
  type        = map(string)
  default = {
    environment = "shared"
    service     = "tfstate"
    managed-by  = "terraform"
  }
}
