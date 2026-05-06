# cloud-lab

cloud security lab tooling. 
Terraform stacks that stand up disposable
infrastructure for hands-on research: running agents, testing
configurations, breaking things in controlled environments.

Each stack is independent — separate state, separate lifecycle, separate
blast radius. Bring up only what you need; tear it down when you're done.

## Stacks

| Directory | Purpose |
|-----------|---------|
| [`gcp-management-tf/`](./gcp-management-tf) | Debian 12 jump box on GCE with Terraform/kubectl/gcloud/Docker preinstalled. Read-only org discovery SA so it can pull kubeconfigs for every GKE cluster the operator can see. SSH via IAP only. |
| [`gcp-gke-tf/`](./gcp-gke-tf) | Minimal private GKE cluster (2x e2-small Spot nodes by default) intended to host security agents alongside deliberately vulnerable workloads. Private nodes, authorized-networks control plane, Dataplane V2. |
| [`aws-eks-tf/`](./aws-eks-tf) | Minimal private EKS cluster (2x t3.small Spot nodes by default) intended to host security agents alongside deliberately vulnerable workloads. Private nodes, CIDR-restricted public endpoint, IMDSv2-only, VPC CNI NetworkPolicy, KMS-encrypted secrets. |
| [`azure-aks-tf/`](./azure-aks-tf) | Minimal AKS cluster (2x Standard_B2s on-demand nodes by default) intended to host security agents alongside deliberately vulnerable workloads. Private nodes behind NAT Gateway, CIDR-restricted public API server, Azure CNI Overlay + Cilium dataplane, AAD-only auth with Azure RBAC for Kubernetes. |

Recommended order: apply `gcp-management-tf` first, SSH into the
management VM, then drive `gcp-gke-tf`, `aws-eks-tf`, and `azure-aks-tf`
from there. The mgmt VM federates into AWS IAM roles and Azure AAD apps
via Workload Identity Federation, so a single SSH session can `kubectl`
into clusters in all three clouds with no long-lived keys or secrets on
disk. State and credentials stay contained to the management server. 

## Multi-cloud kubectl

The operator workflow: SSH the GCP mgmt VM via IAP and `kubectl` into any
GKE / EKS / AKS cluster the lab owns, no per-cluster kubeconfig wrangling
and no static cloud keys on disk (AWS + Azure auth via Workload Identity
Federation; see `proj_roadmap.md` "### P0" for the architecture).

New cluster stacks are picked up automatically: `terraform apply` the
cluster, run `make refresh-from-states` from `gcp-management-tf/`, and
the cluster's context appears in `kubectl config get-contexts` on the
mgmt VM within ~15 minutes. Two systemd timers on the VM
(`mgmt-bootstrap-watch.timer`, `mgmt-refresh-kubeconfigs.timer`) drive
the pickup. See [`gcp-management-tf/README.md`](./gcp-management-tf/README.md#picking-up-a-new-cluster)
for the full flow; `refresh-kubeconfigs --preflight` is the diagnostic
entry point when something doesn't show up.

## Prerequisites

- Terraform >= 1.5 (`aws-eks-tf` and `bootstrap-state/aws` require >= 1.10
  for the S3-native `use_lockfile` backend feature)
- gcloud SDK authenticated against the target org / project
- A GCP project with billing enabled (one per stack is fine; they can
  share a project too)

Each stack's README spells out the specific IAM and API requirements.

## Remote state (optional, recommended)

Each cluster stack ships with local state. To share state across machines
(laptop ↔ mgmt VM, or between teammates), bootstrap the per-cloud state
store first:

| Cloud | Bootstrap stack | Creates |
|-------|-----------------|---------|
| GCP | [`bootstrap-state/gcp/`](./bootstrap-state/gcp) | Versioned GCS bucket, UBLA + public-access-prevention |
| AWS | [`bootstrap-state/aws/`](./bootstrap-state/aws) | Versioned S3 bucket + KMS CMK, S3-native lockfile locking |
| Azure | [`bootstrap-state/azure/`](./bootstrap-state/azure) | RG + LRS Storage Account (AAD-auth only) + container |

Each bootstrap stack is self-bootstrapping (local state) and emits a
`backend_snippet` output. Paste that into the matching sibling stack's
`backend.tf`, copy `backend.hcl.example` → `backend.hcl`, then
`terraform init -backend-config=backend.hcl -migrate-state`.

## Conventions

- **State is local by default.** Each stack ships a commented-out
  backend block plus a `backend.hcl.example`; activate per the
  `bootstrap-state/<cloud>/` README when you need state portability.
- **`terraform.tfvars` is gitignored.** Copy the `.example` file in each
  stack and fill in project IDs, CIDRs, etc.
- **No long-lived keys on disk.** The management VM uses its attached
  GCP service account plus impersonation, and federates into AWS IAM
  roles and Azure AAD apps via Workload Identity Federation — no static
  AWS access keys, no Azure SP secrets. Workstations use ADC.
- **`.terraform/` is gitignored.** Provider binaries are large; let
  `terraform init` fetch them locally.

## Cost

Defaults target "cheap enough to leave running for a week of
experimentation." Stop the management VM when idle; `terraform destroy`
the GKE stack between sessions. Rough numbers live in each stack's
README.
