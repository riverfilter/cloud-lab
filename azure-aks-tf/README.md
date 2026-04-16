# azure-aks-tf — Private AKS Security Lab

Minimal, cost-optimized AKS cluster for a security research lab on Azure. Designed to host security agents (an EDR DaemonSet plus a cluster-level helper StatefulSet) alongside intentionally vulnerable workloads (misconfigured nginx, DVWA, etc.) without exposing those workloads to the internet. Mirror of the `gcp-gke-tf` stack, translated to Azure-native primitives.

## What gets deployed

- Dedicated resource group + VNet (default `10.40.0.0/16`) with a single node subnet
- NAT Gateway attached to the node subnet (egress only; no inbound exposure)
- NSG on the node subnet with explicit deny-inbound-from-Internet
- AKS cluster with Azure CNI **Overlay** + **Cilium** dataplane (free, eBPF, NetworkPolicy enforcement)
- User-assigned managed identity for the control plane, scoped `Network Contributor` on the node subnet only
- Workload Identity + OIDC issuer enabled (pod-level federated AAD auth)
- **Azure RBAC for Kubernetes** on, local accounts disabled — kubectl goes through AAD
- Single default node pool, 2x `Standard_B2s` on-demand by default, 30 GB managed Premium_LRS OS disk each
- Public API server endpoint **restricted** to `authorized_cidrs`
- Weekly Saturday 06:00-10:00 UTC maintenance window
- Optional Spot user node pool (off by default — see cost notes)
- Optional Log Analytics diagnostic settings (off by default)

## Prerequisites

- `terraform` >= 1.5
- `az` CLI authenticated against the target tenant/subscription:
  ```
  az login
  az account set --subscription <subscription-id>
  az account show            # sanity check
  ```
- The applying principal needs enough RBAC to create the resource group and everything in it: at minimum `Contributor` on the target subscription (or a scoped custom role covering Microsoft.Resources, Microsoft.Network, Microsoft.ContainerService, Microsoft.ManagedIdentity, Microsoft.Authorization/roleAssignments/write, Microsoft.OperationalInsights). For a personal lab, a subscription-scoped `Owner` is easiest; tighten this down before reuse in a shared subscription.
- Required resource providers registered on the subscription (one-time):
  ```
  az provider register --namespace Microsoft.ContainerService
  az provider register --namespace Microsoft.OperationalInsights
  az provider register --namespace Microsoft.Network
  az provider register --namespace Microsoft.ManagedIdentity
  ```
- An AAD group whose members will be cluster admins. Create one and grab its object ID:
  ```
  az ad group create --display-name sec-lab-admins --mail-nickname sec-lab-admins
  az ad group member add --group sec-lab-admins --member-id <your-aad-user-object-id>
  az ad group show --group sec-lab-admins --query id -o tsv
  ```

## Deploy

```
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set subscription_id, authorized_cidrs, and admin_group_object_ids
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

State is local by default. For shared use, create a Storage Account + container out of band and uncomment the backend block in `backend.tf`.

## Access the cluster

```
$(terraform output -raw kubectl_configure_command)
kubectl get nodes
```

The cluster has a public API server endpoint restricted to `authorized_cidrs`, so `kubectl` works from any source IP listed there. Because `local_account_disabled = true`, the first kubectl call will trigger an AAD device-code flow — complete it with an account that is a member of one of the `admin_group_object_ids` groups.

## Tear down

```
terraform destroy
```

NAT Gateway, managed identity, and the AKS-managed node resource group all accrue cost while running — destroy between sessions if you are not actively using the lab.

## Rough monthly cost estimate (East US, list prices, April 2026)

| Item                                                     | Approx USD/mo  |
|----------------------------------------------------------|----------------|
| AKS control plane (Free tier — no SLA)                   | $0             |
| 2x Standard_B2s on-demand                                | ~$60           |
| 30 GB Premium SSD LRS OS disk (x2)                       | ~$12           |
| NAT Gateway (fixed hourly)                               | ~$32 + data    |
| NAT Gateway data processing ($0.045/GB)                  | ~$1-3          |
| Public IP (NAT Gateway, Standard)                        | ~$4            |
| Log Analytics (if `enable_diagnostics = true`)           | $0 by default  |
| **Total (2 nodes, on-demand, diagnostics off)**          | **~$110/mo**   |

> **NAT Gateway is the dominant fixed cost**, same story as AWS — ~$32/mo floor even at zero traffic, plus $0.045/GB processed. Switching `outbound_type = "loadBalancer"` in `aks.tf` is one-line-different and moves the egress path to an AKS-managed Standard Load Balancer, which bills per-rule ($0.025/rule-hr) and per-data-processed ($0.005/GB). For a truly idle cluster the LB path costs less; under any real agent + image-pull traffic the NAT Gateway wins on both cost and SNAT-port predictability. The default here favours predictability.

AKS's Free control plane tier is the single biggest cost advantage over EKS (which charges $73/mo flat) — but Free has **no SLA**. Flip `sku_tier = "Standard"` (~$73/mo) for 99.95% uptime. For a lab where a 20-minute control-plane outage costs nothing, Free is the correct default.

Switching `use_spot_vms = true` adds a **separate** Spot user pool on top of the system pool — AKS does not allow the system pool itself to be Spot. That gains you ~70% off the user pool's VMs but adds to the VM floor (the system pool still runs on-demand). For small labs the default `use_spot_vms = false` is typically cheaper unless the Spot pool node count meaningfully exceeds the system pool.

## Agent sizing note

This module does **not** install any specific agent — you bring your own via Helm chart or manifests. The node pool is sized assuming a typical EDR / workload-monitoring agent:

- 1 agent pod per node (DaemonSet) consuming ~500m CPU / 512 Mi–1 GiB memory
- 1 cluster-level helper pod (StatefulSet)

`Standard_B2s` (2 vCPU burstable, **4 GiB RAM**) leaves comfortable headroom for an agent of that size plus a handful of lightweight lab pods. Azure has no 2 GiB burstable at the same price point as GCP's `e2-small`, so B2s ends up with 2 GiB more RAM than its GKE counterpart — a minor win. If you see OOMKilled agent pods or `MemoryPressure` on nodes, bump `node_vm_size` to `Standard_B2ms` (2 vCPU / 8 GiB) or `Standard_D2ads_v5` for a non-burstable profile.

## Warning — vulnerable workloads

> The threat model assumes pods in this cluster can be compromised. The module deliberately:
>
> - Gives nodes no public IPs; they live in a private subnet behind a NAT Gateway.
> - Restricts the AKS API server to `authorized_cidrs` (0.0.0.0/0 is rejected by variable validation).
> - Scopes the control-plane managed identity to `Network Contributor` on the node subnet **only** — not on the VNet, not at the RG.
> - Disables the local Kubernetes admin account. Every kubectl call goes through AAD with Azure RBAC evaluating the caller's role assignments on the cluster resource.
> - Runs the Cilium dataplane — `NetworkPolicy` resources are enforced by eBPF on each node.
>
> It does **not** restrict egress from pods to the internet by default (NAT is open). Before running DVWA or similar, add:
>
> - A default-deny `NetworkPolicy` (or `CiliumNetworkPolicy`) per namespace, explicitly allowlisting what the vulnerable pod actually needs.
> - Optionally, an NSG rule on the node subnet to tighten east-west.
> - Consider Private Endpoints for ACR / Key Vault / Storage so egress can be removed entirely for a fully air-gapped test.
>
> One Azure-specific note: with **Azure CNI Overlay**, pods get IPs from `pod_cidr` and that range is NOT routable outside the VNet — pods reach external services via SNAT through the node's VNet IP, which in turn egresses through the NAT Gateway's public IP. Any upstream allowlist / firewall rule your in-cluster agent relies on should key on the NAT Gateway's static public IP (exposed as the `nat_gateway_public_ip` output), not the pod IP.
>
> Never place a vulnerable pod in the `default` namespace without a policy in front of it.
