# Azure AKS Lab — Roadmap

Living document. Tasks will be checked off as implementation lands.

## Deployment assumptions

- This stack will **not** be applied from the author's local workstation
  without review, and **not** against a shared production subscription. All
  subscription / tenant identity is supplied by the operator at apply-time
  via `terraform.tfvars`.
- No local `az` CLI state, tenant, subscription, or principal from the
  authoring machine has been baked into defaults. `subscription_id`,
  `authorized_cidrs`, and `admin_group_object_ids` are operator-supplied
  with placeholder examples in the example tfvars.
- The applying principal authenticates wherever the apply actually runs
  (CI runner, bastion, workstation) via the Azure SDK default credential
  chain — the stack does not care how.

## Prerequisites the operator must provide before `apply`

- [ ] **`subscription_id`** — target Azure subscription GUID.
- [ ] **`authorized_cidrs`** — at least one /32, no 0.0.0.0/0.
- [ ] **`admin_group_object_ids`** — at least one AAD group GUID. Without
      it no principal has kubectl access after apply (local accounts
      disabled by default).
- [ ] Subscription-level RBAC sufficient to create RG / VNet / AKS /
      Managed Identity / Role Assignment / Log Analytics. A personal lab
      with Owner on the subscription is fine; tighten before reuse in a
      shared subscription.
- [ ] Resource providers registered: Microsoft.ContainerService,
      Microsoft.OperationalInsights, Microsoft.Network,
      Microsoft.ManagedIdentity.
- [ ] (Optional) Storage Account + container if the commented
      `backend.tf` is adopted.

## Tasks

### Phase 1 — Scaffolding
- [x] Write `roadmap.md` (this file)
- [x] `versions.tf` — pin providers (azurerm ~> 4.14)
- [x] `backend.tf` — commented azurerm backend block
- [x] `variables.tf` — all inputs
- [x] `terraform.tfvars.example`
- [x] `providers.tf` — features {} + subscription_id wiring
- [x] `outputs.tf`

### Phase 2 — Networking
- [x] Dedicated Resource Group
- [x] VNet + single node subnet (no separate pod subnet — CNI Overlay)
- [x] NSG with explicit deny-inbound-from-Internet on the node subnet
- [x] NAT Gateway + Standard public IP for egress
- [x] Optional Log Analytics workspace (conditional)

### Phase 3 — IAM / Identity
- [x] User-assigned managed identity for the control plane
- [x] Network Contributor role assignment scoped to the node subnet
- [ ] ACR integration (AcrPull on the kubelet identity) — commented example in iam.tf

### Phase 4 — AKS
- [x] `azurerm_kubernetes_cluster` with CIDR-restricted public API server
- [x] User-assigned identity wired as the control-plane identity
- [x] Azure CNI Overlay + Cilium dataplane + network policy
- [x] outbound_type = userAssignedNATGateway
- [x] OIDC issuer + Workload Identity enabled
- [x] Azure RBAC for Kubernetes + admin_group_object_ids
- [x] local_account_disabled = true (AAD-only by default)
- [x] Default node pool: 1x B2s, 30 GB Managed Premium, no public IPs
- [x] Separate maintenance_configuration — Saturday 06:00-10:00 UTC
- [x] Optional Spot user node pool (conditional, two-pool topology)
- [x] Optional monitor_diagnostic_setting for kube-audit / kube-apiserver logs

### Phase 5 — Docs
- [x] `README.md` — prerequisites, deploy, cost table, agent-sizing note, vulnerable-workload warning
- [x] Update root `/home/n/cloud-lab/README.md` stacks table

### Phase 6 — Verification
- [x] Manual HCL review for syntax issues
- [ ] `terraform fmt -recursive` — **blocked**: terraform not on PATH in the authoring env; run on first use
- [ ] `terraform init` + `terraform validate` — **operator to run**
- [ ] `terraform plan` with real tfvars — **operator to run**
- [ ] Confirm `az aks get-credentials` + AAD login works — **operator to run**
- [ ] Confirm `kubectl get nodes` returns Ready nodes — **operator to run**
- [ ] Confirm `kubectl auth can-i '*' '*'` for an admin-group member — **operator to run**

## Future work

### Etcd encryption and host encryption
- [ ] **Azure Key Vault KMS** for etcd envelope encryption. Requires a
      Key Vault + CMK + access policy for the cluster identity. Skipped
      today because it adds a Key Vault dependency that complicates
      destroy and is overkill for a lab; first item to re-enable if any
      real secrets ever land in the cluster.
- [ ] **Host-level encryption** (`host_encryption_enabled = true` on the
      node pool). Requires the `Microsoft.Compute/EncryptionAtHost`
      feature to be registered on the subscription; left off so the
      stack applies from a fresh subscription without extra steps.

### Endpoint posture
- [ ] **Private cluster** (`private_cluster_enabled = true`) paired with
      a jumpbox stack (the Azure equivalent of `gcp-management-tf`, not
      yet written). Today the public API server is CIDR-restricted,
      which is adequate but still exposes a TLS surface to the internet.
- [ ] Private DNS zone for the private cluster FQDN, either AKS-managed
      or BYO so a future hub-spoke topology can resolve it centrally.

### Node topology
- [ ] **Spot user pool** — today it's a conditional toggle but
      untested. Validate pod scheduling with taints/tolerations +
      real agent workloads, measure interrupt churn.
- [ ] Graviton-equivalent: **Standard_B2pls_v2** (Ampere ARM burstable)
      — ~20% cheaper and most containers are multi-arch now. Would
      need ARM64 support verified for whatever EDR agent is installed.

### Observability
- [ ] **Azure Monitor for Containers** (`oms_agent` block / Container
      Insights) wired to the Log Analytics workspace created by
      `enable_diagnostics`. Expensive — default off.
- [ ] **Azure Monitor managed Prometheus** — `enable_monitor_metrics`
      already exists as a toggle; add default recording rules + a
      Grafana-equivalent Managed Grafana resource.
- [ ] NSG flow logs to a short-retention storage account for the node
      subnet, REJECT-only.

### Governance and compliance
- [ ] **Azure Policy add-on for Kubernetes** (Gatekeeper-based). AKS
      ships a curated CIS-equivalent initiative that's worth enabling
      even on a lab.
- [ ] **Defender for Containers** — overlaps partially with any host-layer
      EDR but lives at the AKS control-plane layer, not the host layer.

### Registry and app identity
- [ ] ACR integration — create an ACR, assign `AcrPull` to the kubelet
      identity, document pull-secret-free image workflow.
- [ ] **Workload Identity federation demo** — sample namespace/SA with a
      federated credential bound to a user-assigned identity, so a
      later "does pod auth actually work end-to-end?" check is a
      five-minute apply.

### Access
- [ ] Second AAD group as a read-only cluster access layer (Azure RBAC
      "Azure Kubernetes Service RBAC Reader"), alongside the
      admin group.
- [ ] Map AAD groups to specific Kubernetes RBAC roles once the cluster
      grows beyond admin-plus-nothing.

### State + CI
- [ ] Remote state: Storage Account + container, uncomment
      `backend.tf`, migrate with `terraform init -migrate-state`.
- [ ] CI apply path via GitHub Actions + OIDC federation to Azure (no
      long-lived client secrets).

## Notes / decisions

- **Single-pool default, Spot opt-in.** AKS system pool can't be Spot, so
  turning on `use_spot_vms` produces a two-pool topology (on-demand system
  B2s + Spot user pool). For a 1-node lab that doubles the VM floor vs.
  staying single-pool on-demand. Default favours the cheaper single-pool
  footprint; document the two-pool cost in README.
- **Azure CNI Overlay + Cilium**, not kubenet, not Azure CNI (non-overlay).
  Overlay sidesteps VNet IP exhaustion by allocating pod IPs from a
  non-VNet CIDR (GKE-style). Cilium is the free eBPF dataplane with
  NetworkPolicy enforcement, equivalent to GKE Dataplane V2 / EKS VPC CNI
  NetworkPolicy.
- **NAT Gateway over LB outbound.** Documented in README; short version is
  NAT Gateway has predictable SNAT ports and cleaner cost behaviour once
  egress is non-trivial. LB outbound is cheaper only at near-zero traffic.
- **User-assigned identity, not system-assigned.** Lets Network Contributor
  be granted *before* the cluster exists, which avoids the first-apply
  permission race. Also survives cluster rebuilds without re-granting.
- **`local_account_disabled = true` by default.** Forces AAD + Azure RBAC
  for every kubectl call, preventing the break-glass static-token
  kubeconfig from being issued. Less convenient than the EKS access-entry
  flow (which is also on) but is the safer lab posture for the threat
  model (vulnerable pods that might exfiltrate a kubeconfig).
- **Free SKU control plane.** No SLA, but the EKS-equivalent flat $73/mo
  is the single biggest list-price gap between the two stacks. Flip to
  Standard (~$73/mo) if uptime ever matters.
- **East US** is the lab default because it has the broadest SKU / service
  / quota coverage and among the lowest list prices for most resources.
  Any region with AKS availability works.
- **No Key Vault KMS** by default. Adds destroy complexity (soft delete,
  purge protection) for negligible lab benefit; re-enable before any real
  secrets live in this cluster.
