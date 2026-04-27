# AWS EKS Lab — Roadmap

Living document. Tasks will be checked off as implementation lands.

## Deployment assumptions

- This stack will **not** be applied from the author's local workstation
  without review, and **not** against a shared production account. All
  account identity is supplied by the operator at apply-time via
  `terraform.tfvars`.
- No local AWS CLI profile, account ID, or principal from the authoring
  machine has been baked into defaults. `authorized_cidrs` and
  `cluster_admin_principal_arns` (a list) are operator-supplied with
  placeholder examples in the example tfvars. The mgmt VM federated role
  ARN is the canonical second entry alongside the operator's own IAM
  user/role ARN.
- The applying principal authenticates wherever the apply actually runs
  (CI runner, bastion, workstation) via the AWS SDK default credential
  chain — the stack does not care how.

## Prerequisites the operator must provide before `apply`

- [ ] **`authorized_cidrs`** — at least one /32, no 0.0.0.0/0.
- [ ] **`cluster_admin_principal_arns`** — list of IAM user/role ARNs
      granted cluster-admin via EKS access entries. Your own ARN is
      obtainable via `aws sts get-caller-identity --query Arn`. Example:
      `["arn:aws:iam::123456789012:user/you"]`. The mgmt VM federated
      role ARN (`arn:aws:iam::<account>:role/<cluster_name>-mgmt-vm`)
      should be added as a second entry — either pre-computed before
      first apply, or appended after first apply by reading the
      `mgmt_vm_role_arn` output. Without at least one entry, no
      principal has kubectl access after apply.
- [ ] Sufficient IAM to create VPC / EKS / EC2 / IAM / KMS / CloudWatch
      Logs resources. A fresh account with an admin user is fine; tighten
      before reuse in a shared account.
- [ ] (Optional) S3 bucket + DynamoDB lock table if the commented
      `backend.tf` is adopted.

## Tasks

### Phase 1 — Scaffolding
- [x] Write `roadmap.md` (this file)
- [x] `versions.tf` — pin providers (aws ~> 5.80, tls ~> 4.0)
- [x] `backend.tf` — commented S3+DynamoDB backend block
- [x] `variables.tf` — all inputs
- [x] `terraform.tfvars.example`
- [x] `providers.tf` — default_tags wiring
- [x] `outputs.tf`

### Phase 2 — Networking
- [x] VPC, IGW, public + private subnets across 2 AZs
- [x] Single NAT Gateway by default; per-AZ opt-in via variable
- [x] Per-AZ private route tables (so per-AZ NAT flip is a no-op refactor)
- [x] Optional VPC flow logs (REJECT-only) to short-retention CloudWatch

### Phase 3 — IAM
- [x] Cluster role + AmazonEKSClusterPolicy
- [x] Node role + Worker / CNI / ECR managed policies
- [x] OIDC provider for IRSA
- [x] EBS CSI IRSA role (conditional)

### Phase 4 — EKS
- [x] KMS CMK with rotation for secrets envelope encryption
- [x] `aws_eks_cluster` with private + restricted-public endpoints
- [x] Control plane log group with pinned retention
- [x] Access entries (API auth mode) + cluster-admin entry for operator
- [x] Launch template: IMDSv2 required, hop limit 2, gp3 encrypted root
- [x] Managed node group, SPOT by default, fixed size 1-3
- [x] Managed add-ons: vpc-cni (NetworkPolicy on), coredns, kube-proxy, ebs-csi

### Phase 5 — Docs
- [x] `README.md` — prerequisites, deploy, cost table, agent-sizing note, vulnerable-workload warning
- [x] Update root `/home/n/cloud-lab/README.md` stacks table

### Phase 6 — Verification
- [x] Manual HCL review for syntax issues
- [ ] `terraform fmt -recursive` — **blocked**: terraform not on PATH in the authoring env; run on first use
- [ ] `terraform init` + `terraform validate` — **operator to run**
- [ ] `terraform plan` with real tfvars — **operator to run**
- [ ] Confirm `aws eks update-kubeconfig` populates `~/.kube/config` — **operator to run**
- [ ] Confirm `kubectl get nodes` returns Ready nodes — **operator to run**
- [ ] Confirm `kubectl auth can-i '*' '*'` for the admin principal — **operator to run**

## Future work

### Tighten the node IAM role
- [ ] **IRSA for VPC CNI** — attach `AmazonEKS_CNI_Policy` to an IRSA role
      scoped to the `aws-node` ServiceAccount, remove it from the node role.
      This is the single biggest least-privilege win for the node IAM role;
      a compromised non-aws-node pod currently inherits ENI-mutation
      permissions through IMDS (mitigated today only by IMDSv2-required +
      NetworkPolicy).
- [ ] Periodically audit attached node-role policies against actual in-pod
      AWS API call patterns (CloudTrail + IAM Access Analyzer).

### State + CI
- [ ] Remote state: create S3 bucket + DynamoDB lock table, uncomment
      `backend.tf`, migrate with `terraform init -migrate-state`.
- [ ] CI apply path via GitHub Actions + OIDC to AWS (no long-lived keys).

### Security services
- [ ] AWS Config recording + conformance pack for EKS / CIS benchmarks.
- [ ] CloudTrail trail for the account (management + data events for S3/Lambda).
- [ ] GuardDuty with the EKS Protection and Runtime Monitoring feature sets
      enabled — overlaps partially with any host-layer EDR but lives at the
      AWS control-plane layer, not the host layer.
- [ ] Security Hub aggregation for the above.

### Scaling and scheduling
- [ ] **Karpenter** as an alternative to the managed node group. Worth
      adopting if the lab starts hosting heterogeneous workloads or if Spot
      interruption churn on a fixed-size MNG gets noisy.
- [ ] Graviton (t4g.small / c7g) node group variant — ~20% cheaper and most
      containers are multi-arch now.

### Endpoint posture
- [ ] **Private-only control plane endpoint** + deploy a bastion (the AWS
      equivalent of `gcp-management-tf`, not yet written). Today the public
      endpoint is CIDR-restricted, which is adequate but still exposes a
      TLS surface to the internet.
- [ ] VPC endpoints for ECR (api + dkr), S3 gateway, STS, EKS, and
      CloudWatch Logs — lets the stack run with a single NAT OR no NAT for
      fully air-gapped experiments.

### Networking
- [ ] IPv6 or dual-stack VPC. EKS supports IPv6-only pods with the VPC CNI
      in IPv6 mode, which sidesteps the IPv4 pod-IP exhaustion problem on
      small-instance node groups.
- [ ] Pod-level security groups (`ENABLE_POD_ENI=true` + SecurityGroupPolicy
      CRs) as a second layer under NetworkPolicy.

### Storage and workloads
- [ ] EBS CSI driver is already wired with IRSA — confirm a StatefulSet
      actually provisions a PVC end-to-end on first run.
- [ ] EFS CSI driver if any workload needs RWX.

### Access
- [ ] Cross-account / cross-principal cluster access entries for a future
      shared operator role (e.g. a read-only SRE entry alongside the
      admin entry the operator creates today).
- [ ] Map the access entry to a specific Kubernetes RBAC group once SSO is
      wired, rather than the built-in `ClusterAdmin` policy.

## Notes / decisions

- **Managed node group over self-managed / Karpenter** for the baseline.
  Fewer moving parts, AWS handles drain + replace on AMI rolls. Karpenter is
  tracked as a future option, not a default.
- **Single NAT Gateway** is the lab default because NAT is by far the most
  expensive piece of the VPC on AWS. Per-AZ NAT is one variable flip away.
- **IMDSv2 hop limit 2**, not 1. Hop limit 1 prevents pods in the default
  bridged namespace from reaching IMDS at all, which breaks the VPC CNI.
  IMDSv2-required already defeats the class of SSRF attacks that made IMDSv1
  dangerous; hop limit 1 is belt-and-braces for a prod cluster, not worth
  the compat tax for this lab.
- **Access entries, not aws-auth ConfigMap.** API-based auth has been GA
  since 2024 and is the modern path. `authentication_mode = "API"` locks
  out the ConfigMap entirely, avoiding the two-source-of-truth footgun.
- **`AmazonEKS_CNI_Policy` attached to the node role** is the expedient
  choice today; the correct long-term posture is IRSA for the aws-node
  service account (first item in "Future work").
- **No `gp3` baseline tuning** — the 3,000 IOPS / 125 MB/s free baseline is
  plenty for a node root volume. Raising iops/throughput costs money and
  has no benefit for a 20 GiB root.
- **`us-east-1`** is the lab default because it has the broadest AMI /
  service / quota coverage and the lowest list prices for most SKUs. Any
  region with 2+ AZs works.
