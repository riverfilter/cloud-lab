terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Matches the floor across gcp-management-tf (~> 6.10) and gcp-gke-tf
      # (~> 6.12); 6.12 satisfies both and lets this stack share plugin cache
      # with the sibling stacks on an operator workstation.
      version = "~> 6.12"
    }
  }
}
