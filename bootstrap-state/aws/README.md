# bootstrap-state/aws

Creates the S3 bucket + KMS CMK that hold Terraform remote state for every
cloud-lab AWS stack (`aws-eks-tf`, any future AWS siblings). Applied with
local state — this stack owns the bucket its siblings will use
(chicken-and-egg).

## Apply

```sh
cd bootstrap-state/aws
terraform init
terraform apply -var bucket_name_prefix=<your-unique-prefix>
```

S3 bucket names live in a global namespace. Pick a `bucket_name_prefix`
tied to your account (e.g. `acme-lab` or your AWS account alias) to keep
the final name (`<prefix>-cloud-lab-tfstate`) unique.

Outputs:

- `bucket_name` — the final bucket name.
- `kms_key_arn` — CMK for state-at-rest encryption. Every principal that
  runs Terraform against this state needs `kms:Encrypt`, `kms:Decrypt`,
  and `kms:GenerateDataKey` on this key.
- `backend_snippet` — paste into each sibling stack's `backend.tf`.
  Replace `<stack-name>/<env>` with e.g. `aws-eks-tf/sec-lab`.

## KMS key policy

`main.tf` attaches an explicit `aws_kms_key_policy` to the tfstate CMK
with two statements:

1. **`RootAdmin`** — `kms:*` for `arn:aws:iam::<account>:root`. Keeps the
   default key-admin grant intact so account-level IAM policies can
   continue to delegate KMS admin in the usual way.
2. **`OperatorStateAccess`** — `kms:Encrypt` / `kms:Decrypt` /
   `kms:GenerateDataKey` / `kms:DescribeKey` for the `sts get-caller-
   identity` ARN that ran `terraform apply` on this bootstrap.

The second statement is what lets an operator scoped down from
`AdministratorAccess` (e.g. a custom role with `s3:*` on the bucket but
no broad `kms:*`) actually write state — without it, the first
sibling-stack `plan` against the bucket fails `AccessDenied` on
`GenerateDataKey`. If your bootstrap operator and your sibling-stack
operator are different principals, re-apply the bootstrap with the
sibling principal authenticated, or extend the policy by hand to grant
both. The policy is replaced wholesale on every apply, so out-of-band
edits are not durable.

## Locking

The emitted backend snippet uses `use_lockfile = true` — S3-native
conditional-write locking, available in Terraform 1.10+. This replaces
the historical DynamoDB lock table and cuts one resource from the
bootstrap. If your operator pin is < 1.10, add an
`aws_dynamodb_table.tfstate_locks` (LockID hash key, PAY_PER_REQUEST) and
swap the snippet to use `dynamodb_table = "<table-name>"` instead of
`use_lockfile`.

## Next step per sibling stack

For each AWS sibling (`aws-eks-tf/`):

1. Open the stack's `backend.tf` and uncomment the `terraform { backend "s3" {...} }` block (or pass values via the `backend.hcl` example alongside).
2. `terraform init -migrate-state` — Terraform prompts to copy local state into the bucket.
3. Commit the updated `backend.tf`; never commit `backend.hcl`.

## Teardown

The bucket ships without `force_destroy`, so `terraform destroy` fails while
any sibling stack still stores state in it. That is deliberate — migrate
every consumer off first.

The S3 bucket and KMS CMK additionally carry
`lifecycle { prevent_destroy = true }`. To intentionally destroy: comment
out the `lifecycle { prevent_destroy = true }` blocks on
`aws_s3_bucket.tfstate` and `aws_kms_key.tfstate`, run `terraform apply`
to remove the lock, then `terraform destroy`. Verify no sibling stacks
reference this state first.
