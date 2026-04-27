# gcp-gke-tf — Private GKE Security Lab

Minimal, cost-optimized, **private** GKE cluster for a security research lab on GCP. Designed to host security agents (an EDR DaemonSet plus a cluster-level helper StatefulSet) alongside intentionally vulnerable workloads (misconfigured nginx, DVWA, etc.) without exposing those workloads to the internet.

## What gets deployed

- Dedicated VPC + subnet with secondary ranges for pods/services
- Cloud Router + Cloud NAT (egress only — no inbound exposure)
- Zonal private GKE cluster (REGULAR release channel, Dataplane V2)
- One node pool, 2x `e2-small` Spot VMs by default, 20 GB pd-standard each
- Dedicated least-privilege node service account
- Workload Identity, Shielded Nodes, legacy metadata disabled
- Public control plane endpoint **restricted** to `authorized_cidrs`

## Prerequisites

- `terraform` >= 1.5
- `gcloud` authenticated against a project with billing enabled:
  ```
  gcloud auth login
  gcloud auth application-default login
  gcloud config set project <your-project-id>
  ```
- Required APIs enabled in the project:
  ```
  gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    artifactregistry.googleapis.com
  ```

## Deploy

```
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set project_id and authorized_cidrs
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

State is local by default. For shared use add a GCS backend in `versions.tf`:

```hcl
backend "gcs" {
  bucket = "my-tf-state-bucket"
  prefix = "gke-sec-lab"
}
```

## Access the cluster

```
$(terraform output -raw kubectl_configure_command)
kubectl get nodes
```

Because the cluster has a public control plane endpoint with authorized networks, `kubectl` works from any source IP listed in `authorized_cidrs`. The nodes themselves have no public IPs.

## Granting the mgmt VM in-cluster admin

The mgmt VM (from `gcp-management-tf`) runs with a GCP service account that already holds `roles/container.clusterViewer` org-wide (see `gcp-management-tf/modules/iam/main.tf`). That IAM role plus the mgmt VM's egress IP being in `authorized_cidrs` is enough to *authenticate* against the cluster's public endpoint, but `clusterViewer` only grants the IAM-side discovery needed to call `gcloud container clusters get-credentials`. It does NOT grant any in-cluster RBAC — every `kubectl get pods` call from the mgmt VM will return `forbidden` until a Kubernetes `ClusterRoleBinding` authorizes the SA subject.

Run this once after the first apply, from a session that already has cluster-admin (typically your workstation):

```bash
kubectl create clusterrolebinding mgmt-vm-admin \
  --clusterrole=cluster-admin \
  --user=<mgmt-vm-sa-email>
```

The `<mgmt-vm-sa-email>` value is the `service_account_email` output of the `gcp-management-tf` stack. GKE maps the inbound OAuth token's identity onto that SA email, so `--user=<email>` is the correct subject (not a `ServiceAccount` kind — the Kubernetes `ServiceAccount` type is cluster-internal and unrelated).

This is a manual post-apply step. An in-cluster manifest applied by this Terraform stack itself (via the `kubernetes` provider + a `kubernetes_cluster_role_binding` resource) would be cleaner, but adds a provider dependency that has to talk to the cluster's API server from wherever `terraform apply` runs — a stretch goal tracked in the project roadmap, not implemented here.

Scope the binding down if `cluster-admin` is broader than needed for your workflow — read-only access for observation-style lab work maps to the built-in `view` ClusterRole; anything that needs to apply manifests wants `edit` or `admin`.

## Tear down

```
terraform destroy
```

## Rough monthly cost estimate (us-central1, list prices, April 2026)

| Item                                          | Approx USD/mo |
|-----------------------------------------------|---------------|
| Zonal GKE control plane                       | ~$72          |
| 2x e2-small Spot VM + 20 GB pd-standard each  | ~$8–12        |
| Cloud NAT (1 gateway, minimal traffic)        | ~$1–3         |
| Logs/metrics (default free tier typical)      | ~$0–2         |
| **Total (2 nodes, Spot)**                     | **~$85/mo**   |

The GKE control plane is the dominant cost. GKE offers a free tier that historically covers one zonal cluster per billing account — if yours applies, monthly cost drops to well under $25. Switching `use_spot_vms = false` adds ~$8/mo per node.

## Agent sizing note

This module does **not** install any specific agent — you bring your own via Helm chart or manifests. The node pool is sized assuming a typical EDR / workload-monitoring agent:

- 1 agent pod per node (DaemonSet) consuming ~500m CPU / 512 Mi–1 GiB memory
- 1 cluster-level helper pod (StatefulSet)

`e2-small` (2 vCPU burstable, 2 GiB RAM) leaves enough headroom for an agent of that size plus a handful of lightweight lab pods. If you see OOMKilled agent pods or `MemoryPressure` on nodes, bump `node_machine_type` to `e2-medium`.

## Warning — vulnerable workloads

> The threat model assumes pods in this cluster can be compromised. The module deliberately:
>
> - Gives nodes no public IPs.
> - Restricts control plane access to `authorized_cidrs`.
> - Attaches a least-privilege node service account.
> - Enables GKE Dataplane V2 so Kubernetes `NetworkPolicy` is enforced.
>
> It does **not** restrict egress from pods to the internet by default (NAT is open). Before running DVWA or similar, add:
>
> - A default-deny `NetworkPolicy` per namespace, explicitly allowlisting what the vulnerable pod actually needs.
> - Optionally, VPC firewall egress deny rules on the `gke-node` / `${cluster_name}-node` network tags.
>
> Never place a vulnerable pod in the `default` namespace without a policy in front of it.
