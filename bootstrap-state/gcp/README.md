# bootstrap-state/gcp

Creates the GCS bucket that holds Terraform remote state for every cloud-lab
GCP stack (`gcp-management-tf`, `gcp-gke-tf`). Applied with local state —
this stack owns the bucket its siblings will use, so it cannot itself live
in that bucket (chicken-and-egg).

## Apply

```sh
cd bootstrap-state/gcp
terraform init
terraform apply -var project_id=<your-gcp-project-id>
```

Outputs:

- `bucket_name` — the globally-unique bucket name (`<project-id>-cloud-lab-tfstate`).
- `backend_snippet` — paste this into each sibling stack's `backend.tf`,
  replacing `<stack-name>` with e.g. `gcp-management-tf` or `gcp-gke-tf`.

## Next step per sibling stack

For each of `gcp-management-tf/` and `gcp-gke-tf/`:

1. Open the stack's `backend.tf` and uncomment the `terraform { backend "gcs" {...} }` block, or fill in `backend.hcl` from the example alongside.
2. `terraform init -migrate-state` — Terraform prompts to copy local state into the bucket.
3. Commit the updated `backend.tf` (never commit `backend.hcl`; it is gitignored).

GCS backends lock natively via the generation-checked lock object; no
DynamoDB-equivalent sidecar is needed.

## Teardown

`terraform destroy` on this stack fails while any other stack still keeps
state in the bucket (`force_destroy = false`). That is intentional —
migrate every consumer off first.

The bucket additionally carries `lifecycle { prevent_destroy = true }`.
To intentionally destroy: comment out the `lifecycle { prevent_destroy = true }`
block on `google_storage_bucket.tfstate`, run `terraform apply` to remove
the lock, then `terraform destroy`. Verify no sibling stacks reference
this state first.
