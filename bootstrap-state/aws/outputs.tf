output "bucket_name" {
  description = "Name of the S3 bucket that holds remote state for every AWS sibling stack."
  value       = aws_s3_bucket.tfstate.bucket
}

output "kms_key_arn" {
  description = "ARN of the KMS CMK used to encrypt tfstate at rest. Any principal that runs Terraform against a state in this bucket needs kms:Encrypt / kms:Decrypt / kms:GenerateDataKey on this key."
  value       = aws_kms_key.tfstate.arn
}

output "backend_snippet" {
  description = "Drop-in backend block for each sibling AWS stack's backend.tf. Replace <stack-name>/<env> with e.g. `aws-eks-tf/sec-lab`. Uses S3-native lockfile locking; requires Terraform >= 1.10."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.tfstate.bucket}"
        key          = "<stack-name>/<env>.tfstate"
        region       = "${var.region}"
        encrypt      = true
        kms_key_id   = "${aws_kms_key.tfstate.arn}"
        use_lockfile = true
      }
    }
  EOT
}
