# bootstrap-state/azure

Creates the Resource Group + Storage Account + blob container that hold
Terraform remote state for every cloud-lab Azure stack (`azure-aks-tf`,
any future Azure siblings). Applied with local state — this stack owns
the container its siblings will use (chicken-and-egg).

## Apply

```sh
cd bootstrap-state/azure
terraform init
terraform apply \
  -var subscription_id=<sub-guid> \
  -var storage_account_name=<globally-unique-3-24-lowercase-alphanum>
```

Storage account names live in a global namespace and are limited to 3-24
lowercase alphanumeric characters (no hyphens). Pick something tied to
your subscription (e.g. `acmelabtf01`).

Outputs:

- `resource_group_name`, `storage_account_name`, `container_name`
- `backend_snippet` — paste into each sibling stack's `backend.tf`,
  replacing `<stack-name>/<env>` with e.g. `azure-aks-tf/sec-lab`.

## Auth posture

`shared_access_key_enabled = false` forces AAD auth for blob data operations
(matches the AKS stack's `local_account_disabled = true`). To run
`terraform init -migrate-state` from a sibling stack, your `az login`
principal needs `Storage Blob Data Contributor` on the container.

Two ways to grant it:

1. **In-stack**: re-apply this bootstrap with
   `-var operator_principal_id=$(az ad signed-in-user show --query id -o tsv)`.
   A count-gated `azurerm_role_assignment` resource will attach the role.
2. **Out-of-band (Portal or CLI)** — leave `operator_principal_id` empty
   and run:
   ```sh
   az role assignment create \
     --assignee $(az ad signed-in-user show --query id -o tsv) \
     --role "Storage Blob Data Contributor" \
     --scope $(terraform output -raw container_resource_id)
   ```

> Bumping a provider pin? See
> [`gcp-management-tf/README.md#bumping-provider-pins`](../../gcp-management-tf/README.md#bumping-provider-pins)
> for the `init -upgrade` lock-file edge case.

## Locking

The azurerm backend uses native blob-lease locking — no sidecar needed.

## Next step per sibling stack

For each Azure sibling (`azure-aks-tf/`):

1. Open the stack's `backend.tf` and uncomment the `terraform { backend "azurerm" {...} }` block (or pass values via `backend.hcl`).
2. `terraform init -migrate-state`.
3. Commit `backend.tf`; never commit `backend.hcl`.

## Teardown

`terraform destroy` on this stack wipes the storage account and its blobs.
Before doing so, migrate every consumer stack off the backend (e.g. flip
each sibling's `backend.tf` back to local + `terraform init -migrate-state`).

The storage account and tfstate container additionally carry
`lifecycle { prevent_destroy = true }`. To intentionally destroy:
comment out the `lifecycle { prevent_destroy = true }` blocks on
`azurerm_storage_account.tfstate` and `azurerm_storage_container.tfstate`,
run `terraform apply` to remove the locks, then `terraform destroy`.
Verify no sibling stacks reference this state first.

Both blob versioning and 30-day soft-delete retention are enabled on
the storage account, so an accidental `terraform destroy` of a sibling
stack can be recovered for 30 days. After that window closes the blobs
are gone permanently — Azure does not honour a tenant-level recovery
process for soft-deleted blob data.
