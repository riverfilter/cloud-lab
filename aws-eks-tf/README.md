# aws-eks-tf — Private EKS Security Lab

Minimal, cost-optimized, **private** EKS cluster for a security research lab on AWS. Designed to host security agents (an EDR DaemonSet plus a cluster-level helper StatefulSet) alongside intentionally vulnerable workloads (misconfigured nginx, DVWA, etc.) without exposing those workloads to the internet. Mirror of the `gcp-gke-tf` stack, translated to AWS-native primitives.

## What gets deployed

- Dedicated VPC (default `10.30.0.0/16`) with public + private subnets across 2 AZs
- Internet Gateway + single NAT Gateway (egress only; per-AZ NAT optional)
- EKS cluster, IMDSv2-only worker nodes, control plane logs (api/audit/authenticator) to CloudWatch
- One managed node group, 2x `t3.small` Spot by default, 20 GB gp3 root volume each
- Dedicated least-privilege node IAM role
- KMS CMK (rotation on) for Kubernetes Secrets envelope encryption
- IAM OIDC provider for IRSA (pod-level AWS identity)
- Managed add-ons: VPC CNI (with native NetworkPolicy enabled), CoreDNS, kube-proxy, optionally EBS CSI driver via IRSA
- Public control plane endpoint **restricted** to `authorized_cidrs`; private endpoint also enabled so in-VPC workloads don't hairpin through NAT
- Cluster-admin access entry for the applying principal

## Prerequisites

- `terraform` >= 1.10 (required for the S3 backend's `use_lockfile = true`,
  which replaces the historical DynamoDB lock table)
- `aws` CLI v2 authenticated against an account with billing enabled:
  ```
  aws configure sso            # or: aws configure
  aws sts get-caller-identity  # sanity check
  ```
- The applying principal needs enough IAM to create VPC, EKS, EC2, IAM, KMS, and CloudWatch Logs resources. For a personal lab, an admin-equivalent user is easiest; tighten this down before reuse in a shared account.
- No service quotas to pre-raise in a fresh account for this footprint.

## Deploy

```
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set authorized_cidrs and cluster_admin_principal_arns
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

State is local by default. For shared use, create an S3 bucket + DynamoDB lock table out of band and uncomment the backend block in `backend.tf`.

## Granting the mgmt VM cluster-admin

The mgmt VM (from `gcp-management-tf`) federates into an AWS IAM role exposed as the `mgmt_vm_role_arn` output of this stack. To give that role cluster-admin, include it in `cluster_admin_principal_arns`:

```hcl
cluster_admin_principal_arns = [
  "arn:aws:iam::123456789012:user/you",                 # operator workstation
  "arn:aws:iam::123456789012:role/sec-lab-mgmt-vm",     # mgmt VM federated role
]
```

**Pre-compute the mgmt VM ARN before the first apply (recommended).** The role ARN is deterministic — `arn:aws:iam::<account>:role/<cluster_name>-mgmt-vm` — so you can construct it from `aws sts get-caller-identity --query Account --output text` and `var.cluster_name` and drop it into `terraform.tfvars` before running `terraform apply` for the first time. This gives the mgmt VM working `kubectl` from the moment the cluster exists.

> **Footnote — the two-apply path (avoid).** It is technically valid to (1) apply once with only the operator ARN in the list, (2) read the `mgmt_vm_role_arn` output after apply, (3) add it to `cluster_admin_principal_arns` and apply again. Don't do this if you can avoid it: between applies the mgmt VM has valid AWS federated creds and `eks:DescribeCluster` (so `aws eks update-kubeconfig` succeeds and looks healthy), but **`kubectl` returns `forbidden` on every call** until the second apply lands. If you forget the second apply, the entire cross-cloud federated-identity feature ships functionally broken on EKS with no error surface. The `mgmt_vm_role_arn` output is only populated when `mgmt_vm_gcp_sa_unique_id` is set (the federated-identity resources are count-gated on that variable).

## Upgrading from a singular `cluster_admin_principal_arn`

> As of 2026-04-27, the list-driven `aws_eks_access_entry.admin` / `aws_eks_access_policy_association.admin` `for_each` pair (keyed on ARN) is the only active code path in this stack. The legacy singular `cluster_admin_principal_arn` variable and the parallel `aws_eks_access_entry.mgmt_vm` resource pair are both gone from source. Operators starting fresh from `master` do not need any migration — populate `cluster_admin_principal_arns` with the operator and mgmt VM ARNs and apply normally. The state-move recipes below are retained only for operators upgrading from a state file produced by an earlier revision.

An earlier revision of this stack used a singular string variable `cluster_admin_principal_arn` and a singular `aws_eks_access_entry.admin` / `aws_eks_access_policy_association.admin` pair. Item 1 of the roadmap also introduced a separate `aws_eks_access_entry.mgmt_vm` / `aws_eks_access_policy_association.mgmt_vm` pair for the federated mgmt VM role. Both have been consolidated into a single list-driven `for_each` resource pair keyed on the ARN. If you have a pre-existing deployment, avoid destroy-and-recreate by moving state before the next apply:

```bash
# If you previously had the singular admin resource:
terraform state mv \
  'aws_eks_access_entry.admin[0]' \
  'aws_eks_access_entry.admin["arn:aws:iam::123456789012:user/you"]'
terraform state mv \
  'aws_eks_access_policy_association.admin[0]' \
  'aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:user/you"]'

# If you applied Item 1 and have the separate mgmt_vm access entry:
terraform state mv \
  'aws_eks_access_entry.mgmt_vm[0]' \
  'aws_eks_access_entry.admin["arn:aws:iam::123456789012:role/sec-lab-mgmt-vm"]'
terraform state mv \
  'aws_eks_access_policy_association.mgmt_vm[0]' \
  'aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:role/sec-lab-mgmt-vm"]'
```

Substitute your real account ID, IAM principal, and `<cluster_name>-mgmt-vm` role name. `terraform plan` after the moves should report no changes on the admin/mgmt_vm access-entry resources. A static `moved { }` block is not written in HCL because the new address keys are ARNs that are only known at apply time (not expressable in source). If you skip the state moves the resources are simply replaced on next apply, which has brief cluster-admin unavailability but no other blast radius in a lab.

> **Alternative pattern — per-operator literal `moved` block.** If you prefer HCL-driven migrations over `terraform state mv`, you can drop a local-only `migrations.tf` next to the rest of the stack containing literal `moved` blocks with your real ARNs hardcoded. `moved` blocks require *constant* keys (variable-referenced indexes are rejected), which is why a generic source-committed version is impossible — but a per-operator file with your account ID and IAM user baked in works fine. Example:
>
> ```hcl
> # migrations.tf — local-only, NOT committed
> moved {
>   from = aws_eks_access_entry.admin[0]
>   to   = aws_eks_access_entry.admin["arn:aws:iam::123456789012:user/you"]
> }
> moved {
>   from = aws_eks_access_policy_association.admin[0]
>   to   = aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:user/you"]
> }
> # ...add the mgmt_vm pair if you applied Item 1.
> ```
>
> Run `terraform apply` once with the file in place; the plan output is cleaner than `state mv` (the moves render as `# ... has moved to ...` lines instead of out-of-band state surgery). Delete `migrations.tf` after the apply succeeds — `moved` blocks are inert once their `to` address matches state, so leaving the file in place is harmless but clutters subsequent plans. Both patterns are equivalent in outcome; pick whichever your team prefers.

## Access the cluster

```
$(terraform output -raw kubectl_configure_command)
kubectl get nodes
```

Because the cluster has a public control plane endpoint with `public_access_cidrs`, `kubectl` works from any source IP listed in `authorized_cidrs`. The nodes themselves have no public IPs and live in private subnets.

> Bumping a provider pin? See
> [`gcp-management-tf/README.md#bumping-provider-pins`](../gcp-management-tf/README.md#bumping-provider-pins)
> for the `init -upgrade` lock-file edge case.

## Tear down

```
terraform destroy
```

NAT Gateways and the control plane accrue cost by the hour even when idle — destroy between sessions if you are not actively using the lab.

## Rough monthly cost estimate (us-east-1, list prices, April 2026)

| Item                                                 | Approx USD/mo |
|------------------------------------------------------|---------------|
| EKS control plane ($0.10/hr, flat)                   | ~$73          |
| 2x t3.small Spot + 20 GB gp3 root each               | ~$10–14       |
| NAT Gateway (1x, minimal traffic)                    | ~$32 + data   |
| CloudWatch Logs (control plane, 7-day retention)     | ~$0–1         |
| KMS CMK                                              | ~$1           |
| **Total (2 nodes, Spot, single NAT)**                | **~$120/mo**  |

> **NAT is the dominant variable cost on AWS**, unlike GCP where Cloud NAT is almost free for a lab-scale workload. Setting `single_nat_gateway = false` roughly doubles the NAT line item (~$32/mo per additional AZ). Removing NAT entirely is possible for a pure offline lab but breaks EKS add-on installs, image pulls from public registries, and any in-cluster agent that needs to reach an external management/ingest endpoint — you would need VPC endpoints for ECR + S3 + STS + EKS at minimum to compensate.

The EKS control plane is the dominant fixed cost (~$73/mo). Unlike GKE, AWS does not offer a free zonal cluster tier, so there's no equivalent "drop to $25/mo" escape hatch. Switching `use_spot_instances = false` adds ~$10-12/mo per t3.small on-demand.

## Agent sizing note

This module does **not** install any specific agent — you bring your own via Helm chart or manifests. The node group is sized assuming a typical EDR / workload-monitoring agent:

- 1 agent pod per node (DaemonSet) consuming ~500m CPU / 512 Mi–1 GiB memory
- 1 cluster-level helper pod (StatefulSet) — enable `enable_ebs_csi_driver` so its PVC provisions

`t3.small` (2 vCPU burstable, 2 GiB RAM) leaves enough headroom for an agent of that size plus a handful of lightweight lab pods. If you see OOMKilled agent pods or `MemoryPressure` on nodes: when `use_spot_instances = false`, bump `node_instance_type` to `t3.medium` (4 GiB). When Spot is on (default), replace `spot_instance_types` with a 4 GiB list, e.g. `["t3.medium", "t3a.medium", "t2.medium"]`.

## Warning — vulnerable workloads

> The threat model assumes pods in this cluster can be compromised. The module deliberately:
>
> - Gives nodes no public IPs; they live in private subnets behind NAT.
> - Restricts the EKS public endpoint to `authorized_cidrs` (0.0.0.0/0 is rejected by variable validation).
> - Attaches a least-privilege node IAM role (worker + CNI + ECR read; nothing else).
> - Requires IMDSv2 on worker nodes (hop limit 2 so pod networking still works). This defeats the classic SSRF-to-instance-credentials attack path.
> - Envelope-encrypts Kubernetes Secrets at rest with a customer-managed KMS key.
> - Enables native NetworkPolicy support in the VPC CNI — `NetworkPolicy` resources are enforced by eBPF on each node.
>
> It does **not** restrict egress from pods to the internet by default (NAT is open). Before running DVWA or similar, add:
>
> - A default-deny `NetworkPolicy` per namespace, explicitly allowlisting what the vulnerable pod actually needs.
> - Consider VPC endpoints for ECR/S3/STS so you can remove NAT entirely for a fully air-gapped test.
>
> The AWS VPC CNI also imposes one thing worth knowing for a security lab: **pods share the node's ENI IP pool and the node's security groups by default**. Pod-level SG isolation is available via `ENABLE_POD_ENI=true` + SecurityGroupPolicy CRs but is not enabled by default here; rely on NetworkPolicy for pod-to-pod controls.
>
> Never place a vulnerable pod in the `default` namespace without a policy in front of it.
