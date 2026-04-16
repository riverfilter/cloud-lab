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
management VM, then drive `gcp-gke-tf` from there so state and
credentials stay contained to the management server. 

## Prerequisites

- Terraform >= 1.5
- gcloud SDK authenticated against the target org / project
- A GCP project with billing enabled (one per stack is fine; they can
  share a project too)

Each stack's README spells out the specific IAM and API requirements.

## Conventions

- **State is local by default.** Each stack ships a commented-out GCS
  backend block; fill it in before sharing the stack with anyone else.
- **`terraform.tfvars` is gitignored.** Copy the `.example` file in each
  stack and fill in project IDs, CIDRs, etc.
- **No long-lived keys on disk.** The management VM uses its attached
  service account plus impersonation; workstations use ADC.
- **`.terraform/` is gitignored.** Provider binaries are large; let
  `terraform init` fetch them locally.

## Cost

Defaults target "cheap enough to leave running for a week of
experimentation." Stop the management VM when idle; `terraform destroy`
the GKE stack between sessions. Rough numbers live in each stack's
README.
