# Remote state backend.
#
# Uncomment and fill in once a GCS bucket exists. The bucket MUST have
# versioning enabled and should live in the host project with uniform
# bucket-level access. Prefer CMEK if this project is subject to
# compliance controls.
#
# Create the bucket out-of-band (chicken-and-egg with Terraform-managed state):
#
#   gsutil mb -p <host_project> -l <region> -b on gs://<bucket>
#   gsutil versioning set on gs://<bucket>
#
# terraform {
#   backend "gcs" {
#     bucket = "REPLACE-ME-tfstate-bucket"
#     prefix = "gcp-management-tf/mgmt-vm"
#   }
# }
