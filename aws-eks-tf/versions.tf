terraform {
  # 1.10+ required: `backend.hcl.example` ships `use_lockfile = true`
  # (S3-native conditional-write locking), which is silently rejected on
  # < 1.10 — failing safely here at `terraform init` is preferable to a
  # confusing `unknown argument` later in the migrate-state flow.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
