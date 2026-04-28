# cloud-lab — Project Roadmap

Living document. Cross-cutting roadmap for the four sibling stacks
(`gcp-management-tf`, `gcp-gke-tf`, `aws-eks-tf`, `azure-aks-tf`).
Per-stack roadmaps continue to track single-stack work; this file
tracks items that span two or more stacks or describe the lab as a
whole.

---

## Operating principles

1. **The three clusters are siblings, not mirrors.** A shared threat
   model (private nodes, restricted control plane, vulnerable-pod
   ready) and a shared cost posture (minimal footprint, Spot where
   safe). Cloud-native idiom wins over forced parity — if AKS
   expresses a concept via `azurerm_monitor_diagnostic_setting` and
   EKS expresses it via `enabled_cluster_log_types`, that divergence
   stays. We do NOT chase identical variable names, matching flow-log
   defaults, or a canonical tag schema for its own sake.
2. **4-8 users, 4–8 pods per cluster, aside from the expected daemonsetnot all running at once.** The
   target footprint is tiny and intermittent. A cluster is routinely
   destroyed when idle and re-applied when needed. Any design
   decision that breaks under `terraform destroy` + re-apply (state
   continuity, stable references from the mgmt VM, predictable IAM
   bootstrap) is a bug; design decisions that "feel prod-shaped"
   (autoscaling, HA NAT, uptime SLA) are anti-features here.
3. **The management VM in GCP is the kubectl entry point for all
   three clouds.** An operator SSH's into the mgmt VM, runs
   `refresh-kubeconfigs`, and gets a `~/.kube/config` populated with
   contexts for every GKE / EKS / AKS cluster currently running.
   Nothing else in the lab is durable — the mgmt VM is the one stable
   surface, and the three cluster stacks are clients to that surface.

The rest of this document is organized around making principle (3)
actually work, plus the genuinely-bug items that don't fit neatly
under it.

---

## Deferred / optional decisions awaiting operator input

These items survived the 2026-04-27 hardening sweep as choices the
implementation could not reasonably make on its own. They are
intentionally NOT marked as bugs — each is a defensible default with a
documented escape hatch. Decide and act when (or if) the trade
matters.

### A. Item 33 — verify CBD chain on first `cluster_name` rename

**Context.** P0#1.6 propagated `lifecycle { create_before_destroy =
true }` through the AAD chain (App → SP → FedCred → role assignment)
in `azure-aks-tf/iam.tf`. The intended plan order on a `cluster_name`
rename is *create-new-everything → destroy-old-everything* — no
auth-gap window. Source review and `terraform validate` are clean,
but Terraform's actual plan order can only be confirmed against a
real rename.

**What to do.** Nothing right now. The next time you rename a
`cluster_name` (e.g. promote `dev` → `prod`, test the rotation, or
edit one character to force a re-plan), capture
`terraform plan` output BEFORE applying. Confirm the order matches
the description in P0#1.6's status entry. If the plan shows a
destroy-then-create on any link in the chain, revisit P0#1.6 — the
chain has a missed CBD edge or a non-CBD-compatible attribute.

**No-action mode is fine.** The chain is correct on inspection and
on `terraform validate`; this is empirical confirmation, not bug
hunting.

### B. Item 40 — commit the new `bootstrap-state/{aws,gcp}/.terraform.lock.hcl`

**Context.** Round 3 generated lock files for `bootstrap-state/aws/`
and `bootstrap-state/gcp/` (`hashicorp/aws 5.100.0` and
`hashicorp/google 6.50.0`, both within `versions.tf` constraints).
They are currently untracked because committing files is an
operator-policy decision the orchestrator deliberately does not make
unilaterally.

**Trade-off.**
- **Commit them** — every operator gets the same provider versions on
  first init; matches `bootstrap-state/azure/.terraform.lock.hcl` and
  the cluster-stack convention. This is the lab's existing pattern
  and the recommended choice.
- **Gitignore them** — gives up reproducibility; only justified if the
  lab routinely tolerates provider drift, which it doesn't (every
  other stack commits lock files). Anti-pattern here.

**What to do.** Run `git add bootstrap-state/aws/.terraform.lock.hcl
bootstrap-state/gcp/.terraform.lock.hcl` and commit alongside the next
batch of changes. One-liner with no functional risk; aligns the three
bootstrap-state siblings.

### C. Item 42 — GKE `node_config.labels` parity with the AKS sub-item fix

**Context.** P2#11's sub-item just removed `var.tags` from AKS
`node_labels` so resource-tag semantics don't leak into Kubernetes
node labels. GKE has the same shape: `gcp-gke-tf/gke.tf:163` does
`node_config.labels = var.labels`, and in the GKE provider
`node_config.labels` ARE Kubernetes node labels (GCE instance labels
are set on the underlying MIG, not here). So `var.labels` defaults
like `environment=lab` are scheduler-visible on GKE nodes today.

**Trade-off.**
- **Option (a) — split `var.labels` into `var.node_labels`.** Adds an
  operator-overridable Kubernetes-label input alongside the existing
  resource-tag map. More flexible, more variables.
- **Option (b) — hardcode the literal map.** Replace
  `node_config.labels = var.labels` with `node_config.labels = {
  "lab.purpose" = "security-research" }` matching the AKS shape.
  Simpler, loses operator-overridability of node labels.

**What to do.** Default recommendation: option (b) for symmetry with
the AKS resolution. Operator note: existing GKE clusters will roll
their node pool on next apply to drop tag-derived labels. Drain
workloads first.

If you want option (b) implemented now, ask the orchestrator to
launch an agent.

### D. P2#12 — `enable_flow_logs` variable for `azure-aks-tf`

**Context.** The roadmap framing is "lazily — flip on if investigating
something." A bool variable without resource wiring would be dead
code. Wiring up NSG flow logs requires Network Watcher + storage
account + retention policy + (optionally) Log Analytics workspace —
non-trivial setup and a real data-charge commitment.

**What to do.** Defer until an actual investigation needs flow logs.
At that point, the operator who needs them is best positioned to
design the wiring (storage class, retention, LAW vs. raw blob). Don't
pre-wire a feature stub.

**No-action mode is the right default.** The roadmap explicitly
contemplates this as lazily-deferred work.

### E. AKS node-pool roll on next apply (operational warning)

**Context.** P2#11's sub-item changes `node_labels` from `merge(
var.tags, {...})` to a literal map. Existing AKS clusters previously
applied with the merged shape will see their default and Spot node
pools roll on the next `terraform apply` to drop the tag-derived
labels (`environment`, `purpose`, `managed-by` — populated from
`var.tags`'s defaults).

**What to do.** Drain workloads on the affected pools before applying.
For a security-research lab where pods are by definition disposable,
this is usually a non-event — but if you have a long-running
investigation in flight, plan the apply timing accordingly. The same
warning applies to Item 42 (GKE) once it lands.

---

## Fixed during this review

- **AKS silently ignored `var.node_count` changes.** `azure-aks-tf/aks.tf`
  had `lifecycle.ignore_changes = [default_node_pool[0].node_count, ...]`.
  With autoscaling disabled, `var.node_count` is the single source of
  truth; ignoring it meant any `node_count` bump applied cleanly but
  produced no actual resize. Removed `default_node_pool[0].node_count`
  from `ignore_changes` (kept `kubernetes_version`, which is deliberately
  ignored to tolerate AKS-initiated patch rolls). Impact: operators can
  now resize the pool via tfvars as documented.
- **`node_count` default normalized to 2** across all three cluster
  stacks (previously: GKE=2, EKS=1, AKS=1). The 2-node floor gives
  enough topology to validate pod-anti-affinity and DaemonSet
  behaviour and is what a 1–2-user lab typically wants anyway.
- **EDR vendor product name purged** from all code comments, variable
  descriptions, READMEs, and per-stack roadmaps. Replaced with
  "EDR agent" / "workload-monitoring agent" phrasing that preserves
  the sizing rationale.

---

## P0 — Multi-cloud kubectl from the management VM

**Arc status: all five design items implemented; each with follow-up
subsections capturing blocking and robustness findings from
post-implementation review.** The functional path — mgmt VM → federated
identity → static egress IP allowlisted → admin access on each cluster
→ `refresh-kubeconfigs` enumerates GKE/EKS/AKS → persistent kubectl
sessions — is in place end-to-end. **All 11 originally-blocking items
across Items 1-5 and the P0-checklist are now closed; the legacy P0
follow-up sections have 0 unchecked boxes remaining** (down from 26
after the 2026-04-27 multi-pass hardening sweep). Items 31-42 (added
during the sweep as new findings) carry their own status: 9 closed
(Items 31-32, 34-39, 41 — code/doc fixes shipped), 1 deferred-
operational (Item 33 — verifies on next `cluster_name` rename, no code
needed), 1 partial (Item 40 — lock files generated, commit decision
left to operator), 1 open (Item 42 — GKE node_config.labels parity
with AKS P2#11 sub-item, surfaced during Round 4 review). P2#11
sub-item and P2#17 (gcp-gke-tf/roadmap.md) also shipped in Round 4.
Remaining items are quality polish rather than functional gaps.

This is the headline arc. Everything under this section exists to
make a single command — `refresh-kubeconfigs` on the mgmt VM —
produce a working `~/.kube/config` that can talk to any combination
of GKE, EKS, and AKS clusters currently spun up.

Today only GKE works. Extending to EKS and AKS requires:

- **Identity** — the mgmt VM's GCP SA needs to authenticate to AWS
  and Azure without long-lived keys (item 1).
- **Connectivity** — the mgmt VM's egress IP needs to be allowlisted
  on each cluster's control-plane endpoint (item 2).
- **Authorization** — the federated principal needs
  cluster-admin/operator access on each cluster (item 3).
- **Tooling + discovery** — `aws` and `az` CLIs need to be on the
  VM, and `refresh-kubeconfigs` needs to enumerate EKS/AKS clusters
  (item 4).

Item 5 (remote state) is here because destroy/re-apply cycles on the
cluster stacks are routine, and local state breaks under that
workflow.

### 1. Cross-cloud federated identity for the management VM

**Status:** Complete with caveats. Implemented across all three stacks;
0 blocking + 6 robustness follow-ups tracked in `P0 Item 1 — follow-up
from implementation review`.

**Why it matters.** The mgmt VM needs to call `aws eks
describe-cluster` and `az aks get-credentials` from inside GCP,
without static AWS access keys or Azure service principal secrets on
disk. Both AWS and Azure support Workload Identity Federation (WIF)
with GCP as the OIDC issuer — the mgmt VM's GCP SA signs a JWT, AWS
STS / Azure AAD validates it, and returns short-lived credentials.
No secrets to rotate, no keys to lose, no Vault required.

Today, `gcp-management-tf/modules/iam/main.tf` grants the VM SA
org-level GCP discovery roles only. There is no trust relationship
with AWS or Azure, and no AWS/Azure CLI on the VM to use one.

**Architecture.**

```
    mgmt VM (GCP)
        |
        | (1) instance metadata → GCP SA ID token (OIDC JWT)
        v
    +-- AWS STS --------------------------+       +-- Azure AAD -----------------+
    | AssumeRoleWithWebIdentity:          |       | federated token exchange:    |
    |   OIDC provider = accounts.google   |       |   issuer = accounts.google   |
    |   subject = <GCP SA unique_id>      |       |   subject = <SA unique_id>   |
    |   -> IAM role: cloud-lab-mgmt-vm    |       |   -> AAD App + SP            |
    +-------------------------------------+       +------------------------------+
             |                                              |
             v                                              v
      aws eks describe-cluster                       az aks get-credentials
      aws eks get-token (for kubectl)                kubelogin convert-kubeconfig
```

**Affected stacks.**

- `gcp-management-tf` — expose the VM SA's numeric unique_id as an
  output and document it as a required input to the other stacks.
- `aws-eks-tf` — add an IAM OIDC provider for `accounts.google.com`,
  an IAM role with a trust policy keyed to the GCP SA's unique_id,
  and permission policies for EKS describe + access entry creation.
- `azure-aks-tf` — add an AAD Application + Service Principal, a
  federated credential on the App trusting GCP's OIDC issuer with the
  GCP SA's unique_id as subject, and an AAD group membership or
  direct Azure RBAC role assignment for AKS access.

**Proposed Terraform — AWS side (`aws-eks-tf/iam.tf` new block).**

```hcl
variable "mgmt_vm_gcp_sa_unique_id" {
  description = "Numeric unique_id of the GCP service account attached to the management VM. Used as the OIDC subject in the AWS trust policy. Get it from the gcp-management-tf output `service_account_unique_id` (add this output; see project roadmap). Empty string disables federated access for this stack."
  type        = string
  default     = ""
}

# OIDC provider for GCP — shared across all AWS accounts the lab touches.
# Thumbprint list uses Google's current root CA SHA-1. This almost never
# rotates; AWS caches it and rotation just means running terraform apply.
resource "aws_iam_openid_connect_provider" "gcp" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  url            = "https://accounts.google.com"
  client_id_list = ["sts.amazonaws.com"]
  # Google's root CA thumbprint (verify before first apply):
  #   curl -s https://www.googleapis.com/oauth2/v3/certs | ... or use AWS CLI
  #   aws iam get-open-id-connect-provider equivalents.
  thumbprint_list = ["08745487e891c19e3078c1f2a07e452950ef36f6"]
}

# Role the GCP SA can assume.
resource "aws_iam_role" "mgmt_vm_federated" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  name = "${var.cluster_name}-mgmt-vm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.gcp[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "accounts.google.com:aud" = "sts.amazonaws.com"
          "accounts.google.com:sub" = var.mgmt_vm_gcp_sa_unique_id
        }
      }
    }]
  })
}

# Minimum set to discover + kubectl into the cluster.
resource "aws_iam_role_policy" "mgmt_vm_federated" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  name = "${var.cluster_name}-mgmt-vm"
  role = aws_iam_role.mgmt_vm_federated[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

# Access entry wiring — the federated role gets cluster-admin on the
# cluster. Reuses the same aws_eks_access_entry pattern as the operator
# principal; see project roadmap item 3 for the consolidated shape.
resource "aws_eks_access_entry" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.mgmt_vm_federated[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.mgmt_vm_federated[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }

  depends_on = [aws_eks_access_entry.mgmt_vm]
}

output "mgmt_vm_role_arn" {
  description = "ARN of the IAM role the mgmt VM's GCP SA federates into. Feed this to the mgmt VM's AWS config profile."
  value       = try(aws_iam_role.mgmt_vm_federated[0].arn, null)
}
```

**Proposed Terraform — Azure side (`azure-aks-tf/iam.tf` new block).**

```hcl
variable "mgmt_vm_gcp_sa_unique_id" {
  description = "Numeric unique_id of the GCP service account attached to the management VM. Used as the OIDC subject in the AAD federated credential. Empty string disables federated access."
  type        = string
  default     = ""
}

resource "azuread_application" "mgmt_vm" {
  count        = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1
  display_name = "${var.cluster_name}-mgmt-vm"
}

resource "azuread_service_principal" "mgmt_vm" {
  count     = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1
  client_id = azuread_application.mgmt_vm[0].client_id
}

resource "azuread_application_federated_identity_credential" "mgmt_vm" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  application_id = azuread_application.mgmt_vm[0].id
  display_name   = "gcp-mgmt-vm"
  description    = "Trusts the GCP mgmt VM SA to assume this app's identity."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://accounts.google.com"
  subject        = var.mgmt_vm_gcp_sa_unique_id
}

# RBAC on the cluster: "Azure Kubernetes Service RBAC Cluster Admin"
# scoped to just this cluster.
resource "azurerm_role_assignment" "mgmt_vm_aks_admin" {
  count = var.mgmt_vm_gcp_sa_unique_id == "" ? 0 : 1

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_service_principal.mgmt_vm[0].object_id
}

output "mgmt_vm_app_client_id" {
  description = "AAD App client_id the mgmt VM federates into. Feed this to the mgmt VM's az config."
  value       = try(azuread_application.mgmt_vm[0].client_id, null)
}

output "mgmt_vm_tenant_id" {
  description = "AAD tenant_id. Feed this to the mgmt VM's az config."
  value       = data.azurerm_client_config.current.tenant_id
}
```

Requires adding the `azuread` provider to
`azure-aks-tf/versions.tf`.

**Proposed Terraform — GCP side (`gcp-management-tf/outputs.tf` and
`gcp-management-tf/modules/iam/outputs.tf`).**

```hcl
# modules/iam/outputs.tf
output "service_account_unique_id" {
  description = "Numeric unique_id of the mgmt VM SA. Required by AWS and Azure WIF trust policies."
  value       = google_service_account.mgmt_vm.unique_id
}

# root outputs.tf — expose the module output
output "service_account_unique_id" {
  description = "Pass this to aws-eks-tf and azure-aks-tf as var.mgmt_vm_gcp_sa_unique_id."
  value       = module.iam.service_account_unique_id
}
```

The mgmt VM then carries AWS + Azure config pointing at these
federated principals (see item 4).

### 2. Mgmt VM egress IP must be in every cluster's `authorized_cidrs`

**Status:** Complete with caveats. Static NAT IP reserved and exposed
as `nat_public_ip`; tfvars examples updated. 0 blocking + 4 robustness
follow-ups tracked in `P0 Item 2 — follow-up from implementation
review`. Sub-item 3 (`refresh-kubeconfigs --preflight`) explicitly
deferred and still open in the P0-checklist.

**Why it matters.** Each cluster's control-plane endpoint is
CIDR-restricted. Today `authorized_cidrs` defaults to empty in
every cluster stack, and the READMEs say "put your workstation /32
here." The mgmt VM is the intended kubectl entry point, but its
egress IP isn't in any allowlist today — so even if item 1 wires up
the identity, the TCP handshake to the control plane fails.

The mgmt VM egresses through Cloud NAT
(`gcp-management-tf/modules/network/main.tf`). Today the NAT
allocates its IPs automatically (`nat_ip_allocate_option =
"AUTO_ONLY"`). Auto IPs can change on NAT rebuild — fine for apt +
github egress, not fine for a control-plane allowlist.

**Proposed fix — two coordinated changes.**

1. **Switch Cloud NAT to a reserved static IP** in
   `gcp-management-tf/modules/network/main.tf`:

```hcl
resource "google_compute_address" "nat" {
  name   = "${var.name_prefix}-nat-ip"
  region = var.region
}

resource "google_compute_router_nat" "nat" {
  # ... existing fields ...
  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = [google_compute_address.nat.self_link]
}

# Expose at module output level:
output "nat_public_ip" {
  value = google_compute_address.nat.address
}
```

   Propagate that output through root `outputs.tf`:

```hcl
output "nat_public_ip" {
  description = "Static egress IP of the mgmt VM. Include this /32 in each cluster's authorized_cidrs."
  value       = module.network.nat_public_ip
}
```

2. **Feed that IP into each cluster's `authorized_cidrs`** via
   tfvars or `terraform_remote_state`. The ergonomic path: each
   cluster stack's tfvars has an extra entry:

```hcl
# gcp-gke-tf/terraform.tfvars (example)
authorized_cidrs = [
  {
    cidr_block   = "203.0.113.42/32"
    display_name = "my-workstation"
  },
  {
    cidr_block   = "198.51.100.99/32"     # <- mgmt VM NAT IP
    display_name = "mgmt-vm-gcp"
  },
]
```

   For `aws-eks-tf` and `azure-aks-tf` the variable is a list of
   strings rather than objects, but the principle is identical.

3. **Operator UX.** The mgmt VM's `refresh-kubeconfigs` should
   `curl https://ifconfig.me` on startup and log a warning if its
   apparent egress IP doesn't match what's in any cluster's
   allowlist. Proposal: a diagnostic subcommand
   `refresh-kubeconfigs --preflight` that probes each cluster's
   endpoint with a short TCP timeout and reports which are
   reachable.

### 3. Cluster-admin bootstrap must accept the mgmt VM's federated principal

**Status:** Complete with caveats. EKS admin list consolidated with
validation + `for_each`; Item 1's separate `aws_eks_access_entry.mgmt_vm`
absorbed into the list; GKE in-cluster RBAC documented in
`gcp-gke-tf/README.md` (option (1)); AKS already satisfied via Item 1.
0 blocking + 4 robustness follow-ups tracked in `P0 Item 3 — follow-up
from implementation review`. Stretch-goal option (2) (Kubernetes
provider for GKE binding) deferred.

**Why it matters.** Item 1 creates the federated AWS role / AAD SP,
but each cluster stack's admin-bootstrap variable today accepts a
single principal (EKS: `cluster_admin_principal_arn`; AKS:
`admin_group_object_ids`). Both must accept *at least two*
principals in parallel: the operator (workstation IAM user / AAD
user) AND the mgmt VM's federated principal.

Also — and this was flagged in the previous review — EKS has no
variable-level validation that `cluster_admin_principal_arn` is
non-empty. Combined with
`bootstrap_cluster_creator_admin_permissions = false` at
`aws-eks-tf/eks.tf:64`, a fresh apply with the default empty string
produces a cluster with zero admins that nobody can recover.

**Proposed fix — consolidate into a list variable.**

EKS:

```hcl
# aws-eks-tf/variables.tf — replace cluster_admin_principal_arn
variable "cluster_admin_principal_arns" {
  description = "List of IAM principal ARNs to grant cluster-admin via access entries. Typically includes both an operator (workstation user/role) and the mgmt VM's federated role (see var.mgmt_vm_gcp_sa_unique_id). Must be non-empty — bootstrap_cluster_creator_admin_permissions is false, so without at least one entry the cluster has no admins."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "cluster_admin_principal_arns must contain at least one ARN. An empty list produces an unusable cluster."
  }

  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/", arn))
    ])
    error_message = "Every entry must be an IAM user or role ARN."
  }
}

# aws-eks-tf/eks.tf — replace the singular resource with a for_each
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }

  depends_on = [aws_eks_access_entry.admin]
}
```

This also replaces the separate `aws_eks_access_entry.mgmt_vm` from
item 1 — the mgmt VM role ARN just gets appended to the same list.

AKS: `admin_group_object_ids` is already a list. The mgmt VM path
can either (a) add the mgmt VM's SP object_id directly as a separate
`azurerm_role_assignment` (as shown in item 1), or (b) nest the SP
inside an AAD group and include that group's object_id in the list.
Option (a) is simpler; option (b) scales if there's ever more than
one federated principal. Default to (a).

GKE: there's nothing to change on the cluster stack itself — GCP's
kubectl auth path is IAM + `authorized_cidrs`, and the mgmt VM SA
already has `roles/container.clusterViewer` org-wide via
`gcp-management-tf/modules/iam/main.tf:29`. The mgmt VM also needs
*in-cluster* RBAC for anything beyond discovery. Document this in
`gcp-gke-tf/README.md` with a worked example:

```bash
# After first apply:
kubectl create clusterrolebinding mgmt-vm-admin \
  --clusterrole=cluster-admin \
  --user=<mgmt-vm-sa-email>
```

(An in-cluster YAML manifest applied by the GKE stack itself would
be cleaner but adds a Kubernetes provider dependency; leave as a
stretch goal.)

### 4. `refresh-kubeconfigs` must discover EKS and AKS clusters

**Status:** Complete with caveats. All three sub-tasks (4a CLI installs,
4b federated-principals.json + Terraform variables, 4c refresh-script
rewrite) landed together with P0-sessions wiring and P0-azsubs
multi-subscription support. 0 blocking + 6 robustness follow-ups
tracked in `P0 Item 4 — follow-up from implementation review` — the
three originally-blocking items (`RuntimeDirectory=mgmt` token
persistence, `az login --federated-token` leak via `/proc/*/cmdline`,
profile.d exports only visible in login shells) are now resolved.

**Why it matters.** Today the script at
`gcp-management-tf/scripts/bootstrap.sh.tpl:293-356` iterates GCP
projects and runs `gcloud container clusters list`. It has no AWS
or Azure path. For items 1–3 to pay off, the script needs two new
passes.

**Proposed fix — three sub-tasks.**

**4a. Install aws + az CLIs on the mgmt VM.** In
`bootstrap.sh.tpl`, phase 3 ("apt repositories") and phase 4
("package install") — add:

```bash
# AWS CLI v2 — not in Debian repos; fetch installer
if ! command -v aws >/dev/null; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/awscli.zip" \
    "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --update
  rm -rf "$tmp"
fi

# Azure CLI — Microsoft ships a Debian apt repo
if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/azure-cli.list
apt-get update -y
apt-get install -y azure-cli

# kubelogin — required for AKS AAD auth with local_account_disabled=true
KUBELOGIN_VERSION="v0.1.4"
if ! command -v kubelogin >/dev/null; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/kubelogin.zip" \
    "https://github.com/Azure/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin-linux-amd64.zip"
  unzip -q "$tmp/kubelogin.zip" -d "$tmp"
  install -m 0755 "$tmp/bin/linux_amd64/kubelogin" /usr/local/bin/kubelogin
  rm -rf "$tmp"
fi
```

**4b. Provision AWS + Azure credential helpers via Terraform.** The
mgmt VM needs to know *which* AWS role ARN and *which* Azure
tenant/client ID to federate into. Today this is not wired. Options:

- **Option A — metadata-driven.** Terraform writes a small JSON
  config to the VM's startup-script-metadata:

```hcl
# gcp-management-tf — new variable accepting remote-state or
# cross-stack inputs
variable "aws_role_arns" {
  description = "AWS IAM role ARNs the mgmt VM should federate into, keyed by a short label. Sourced from each aws-eks-tf stack's `mgmt_vm_role_arn` output."
  type        = map(string)
  default     = {}
}

variable "azure_federated_apps" {
  description = "Azure AAD App client IDs (and tenant) the mgmt VM should federate into. Keyed by cluster label."
  type = map(object({
    client_id = string
    tenant_id = string
  }))
  default = {}
}
```

   The bootstrap script renders
   `/etc/mgmt/federated-principals.json` and
   `refresh-kubeconfigs` reads it.

- **Option B — convention-driven.** The mgmt VM uses the GCP SA's
  ID token to call a well-known `list-clusters` endpoint per cloud
  and auto-discovers. More magic; less explicit.

Prefer Option A for reviewability.

**4c. Extend `refresh-kubeconfigs`.** Rewrite the script to three
phases:

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG=/etc/mgmt/federated-principals.json

# --- GCP (existing, unchanged) ---
# ... existing GKE loop ...

# --- AWS ---
# Credentials are NOT minted inline here — that pattern broke persistent
# kubectl sessions (env vars vanish when the script exits). See P0-sessions
# below: a systemd timer refreshes a GCP SA ID token file, and an
# ~/.aws/config profile with `web_identity_token_file` lets the AWS SDK
# pick it up on every call. This block only does discovery.
if [[ -f "$CONFIG" ]] && command -v aws >/dev/null; then
  jq -r '.aws_role_arns | to_entries[] | "\(.key) \(.value)"' "$CONFIG" | \
  while read -r label role_arn; do
    echo "[refresh-kubeconfigs] AWS: $label ($role_arn)"
    # Discover clusters in every configured region
    for region in us-east-1 us-west-2; do
      mapfile -t CLUSTERS < <(AWS_PROFILE="mgmt-vm-$label" aws eks list-clusters --region "$region" --query 'clusters[]' --output text 2>/dev/null)
      for c in "${CLUSTERS[@]}"; do
        [[ -z "$c" ]] && continue
        AWS_PROFILE="mgmt-vm-$label" aws eks update-kubeconfig --region "$region" --name "$c" \
          --alias "aws-$label-$c" >/dev/null || true
      done
    done
  done
fi

# --- Azure ---
# No `az login` / `az logout` here — that pattern wipes credentials the
# moment the script finishes. See P0-sessions: the bootstrap exports
# AZURE_FEDERATED_TOKEN_FILE / AZURE_CLIENT_ID / AZURE_TENANT_ID via
# /etc/profile.d, and `kubelogin convert-kubeconfig -l workloadidentity`
# reads those at kubectl time. This block only does discovery.
if [[ -f "$CONFIG" ]] && command -v az >/dev/null; then
  jq -r '.azure_federated_apps | to_entries[] | "\(.key) \(.value.client_id) \(.value.tenant_id)"' "$CONFIG" | \
  while read -r label client_id tenant_id; do
    echo "[refresh-kubeconfigs] Azure: $label"
    mapfile -t ROWS < <(az aks list --query '[].{n:name,g:resourceGroup}' -o tsv)
    for row in "${ROWS[@]}"; do
      [[ -z "$row" ]] && continue
      name=$(awk '{print $1}' <<<"$row")
      rg=$(awk '{print $2}' <<<"$row")
      az aks get-credentials --name "$name" --resource-group "$rg" \
        --context "azure-$label-$name" --overwrite-existing >/dev/null || true
      # Convert to kubelogin workloadidentity mode (reads env vars, no az call at token time)
      kubelogin convert-kubeconfig -l workloadidentity >/dev/null || true
    done
  done
fi

echo "[refresh-kubeconfigs] contexts:"
kubectl config get-contexts -o name
```

All three sections tolerate the mgmt VM being offline from a given
cloud — a cluster that isn't running doesn't block refreshes of the
clusters that are.

### 5. Remote state

**Status:** Complete with caveats. Three `bootstrap-state/<cloud>/`
stacks landed (GCS + S3/KMS with `use_lockfile` + Azure Storage with
AAD-only auth) plus commented `backend.tf` + `backend.hcl.example`
in every sibling stack. 0 blocking + 5 robustness follow-ups tracked
in `P0 Item 5 — follow-up from implementation review`. The three
blocking items (`prevent_destroy` on state buckets / KMS / storage
account, Terraform 1.10+ floor on sibling `versions.tf`, explicit CMK
key policy granting operator principals) plus the soft-delete
retention robustness item have been addressed. Conversion of the
paste-dance to `terraform_remote_state` data sources is still owed
(tracked in P0-checklist Cross-stack / tfvars).

**Why it matters.** Cluster stacks are routinely destroyed and
re-applied under this operating model. Local state on the mgmt VM
(or a laptop) makes that workflow fragile: a `terraform destroy`
followed by a reimage loses the record of what was torn down, and
re-applying the cluster stack from a different machine (laptop →
mgmt VM, or vice versa) requires manual state juggling.

The secrets-on-disk concern from earlier versions of this roadmap
is a smaller worry given the lab's tiny footprint, but
state-portability across machines is the real value prop here.

**Proposed fix.** Add a tiny `bootstrap-state/<cloud>/` stack per
cloud that creates the state bucket + lock primitive + encryption
once, outputs the backend snippet, and is itself applied with local
state (self-bootstrapping).

GCP example (`bootstrap-state/gcp/main.tf`):

```hcl
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-cloud-lab-tfstate"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }
}

output "backend_snippet" {
  value = <<-EOT
    terraform {
      backend "gcs" {
        bucket = "${google_storage_bucket.tfstate.name}"
        prefix = "<stack-name>"
      }
    }
  EOT
}
```

Equivalents for AWS (S3 + DynamoDB lock + KMS) and Azure (Storage
Account + blob lease).

Uncomment each sibling stack's `backend.tf` after the bootstrap is
applied, paste the matching snippet.

### P0-checklist. Execution tasks for the arc

Items 1–5 above describe the *design*. The checkboxes here track the
*work* that still has to land in files. Per-stack roadmaps continue
to own intra-stack tasks; this list exists so the cross-stack
dependencies stay visible in one place.

#### gcp-management-tf

- [x] Expose `service_account_unique_id` as a module output
      (`modules/iam/outputs.tf`) and as a root output
      (`outputs.tf`). **Done (Item 1).**
- [x] Add `aws_role_arns` (map(string)) and `azure_federated_apps`
      (map(object({client_id, tenant_id}))) variables to the root
      stack; thread them through `main.tf` into the bootstrap
      templatefile call at `main.tf:82-86`. **Done (Item 4).**
      `azure_federated_apps` also carries optional `subscription_ids`
      per P0-azsubs.
- [x] Add `aws_regions` (list(string), default
      `["us-east-1","us-west-2"]`) to parameterise the AWS discovery
      loop proposed in item 4c. **Done (Item 4).**
- [x] Render `/etc/mgmt/federated-principals.json` from the
      bootstrap template using those variables; ensure the file is
      owned by root and readable by the persona user. **Done (Item 4).**
- [x] Switch Cloud NAT to a reserved static IP (item 2) and expose
      `nat_public_ip` as a root output so operators can paste it
      into each cluster's `authorized_cidrs`. **Done (Item 2).**
- [x] Add a preflight subcommand
      (`refresh-kubeconfigs --preflight`) that reports egress IP
      and TCP-reachability of each configured cluster endpoint.
      **Done.** `preflight_main` in `bootstrap.sh.tpl:606` curls
      `ifconfig.me` (fallback `api.ipify.org`) for the egress IP, then
      iterates GKE / EKS / AKS — describing each cluster, TCP-probing
      port 443 with a 5s timeout, and noting whether the egress IP is
      listed in each cluster's `authorized_cidrs` /
      `publicAccessCidrs` / `apiServerAccessProfile.authorizedIpRanges`.
      Final summary line reports reachable / unreachable counts and
      flags clusters whose CIDR list is missing the egress IP. Triggered
      by `case "$${1:-}"` dispatch at the top of `refresh-kubeconfigs`;
      no kubeconfig writes in preflight mode.
- [x] Persistent-session wiring (see P0-sessions below): install a
      token-refresh timer/daemon and a `~/.aws/config` profile that
      uses `web_identity_token_file` so kubectl sessions outlive a
      single `refresh-kubeconfigs` invocation. **Done with caveats
      (Item 4 / P0-sessions).** Three blocking follow-ups in
      `P0 Item 4 — follow-up from implementation review`
      (RuntimeDirectory persistence, token leak via cmdline,
      profile.d only sourced in login shells).
- [x] GKE context alias consistency. **Done with caveats (Item 4).**
      Renamed to `gke-<project>-<cluster>` (not the proposed
      `gke-<label>-<name>` — GCP has no operator-supplied label
      analogue). Multi-location collision follow-up tracked under
      Item 4.
- [x] Port the `scoped_roles` list in
      `modules/iam/main.tf:29-34` — no change needed. **Verified
      (no action required).** `compute.viewer` stays org-scoped; the
      mgmt VM needs no additional GCP roles for the cross-cloud arc.

#### aws-eks-tf

- [x] Add `mgmt_vm_gcp_sa_unique_id` variable + OIDC provider for
      `accounts.google.com` + federated IAM role + role policy
      (`eks:DescribeCluster`, `eks:ListClusters`). **Done (Item 1).**
      Inline policy also grants `sts:GetCallerIdentity` for debug
      tooling.
- [x] Consolidate `cluster_admin_principal_arn` (singular, string,
      no validation) at `variables.tf:72-76` into
      `cluster_admin_principal_arns` (plural, list, non-empty
      validation, ARN-shape validation). Replace the single-count
      access-entry + access-policy-association pair at
      `eks.tf:105-125` with `for_each`. **Done (Item 3).**
- [x] Expose `mgmt_vm_role_arn` as an output so
      `gcp-management-tf` can consume it via `terraform_remote_state`
      or manual paste into `var.aws_role_arns`. **Done (Item 1).**
- [x] Rename output `cluster_region` at `outputs.tf:6` to
      `cluster_location` for cross-stack symmetry (item 8).
      **Done.** Renamed without a backwards-compat alias (no internal
      consumers existed). Also added a sibling `nat_gateway_public_ips`
      output (list, one element per AZ unless `single_nat_gateway = true`)
      mirroring AKS's `nat_gateway_public_ip`.

#### azure-aks-tf

- [x] Add the `azuread` provider to `versions.tf` (currently only
      `azurerm` is pinned). **Done (Item 1).** Pinned `~> 3.0`; empty
      `provider "azuread" {}` block (tenant-pin follow-up tracked in
      Item 1 review).
- [x] Add `mgmt_vm_gcp_sa_unique_id` variable + AAD Application +
      Service Principal + federated credential + role assignment
      ("Azure Kubernetes Service RBAC Cluster Admin" scoped to the
      cluster). **Done (Item 1).**
- [x] Expose `mgmt_vm_app_client_id` and `mgmt_vm_tenant_id` as
      outputs so `gcp-management-tf` can consume them via
      `var.azure_federated_apps`. **Done (Item 1).**
- [x] Rename output `location` at `outputs.tf:16` to
      `cluster_location` for cross-stack symmetry (item 8).
      **Done.** Renamed without a backwards-compat alias; description
      reworded to match the new name. AKS's `nat_gateway_public_ip`
      already existed and is unchanged.

#### gcp-gke-tf

- [x] Bootstrap the mgmt VM SA into in-cluster RBAC. **Done with
      caveats (Item 3).** Took option (1): documented the
      `kubectl create clusterrolebinding mgmt-vm-admin` step in
      `gcp-gke-tf/README.md`. Option (2) (Kubernetes-provider
      automation) remains a stretch goal.
- [x] Accept a `mgmt_vm_sa_email` variable so the binding in (2)
      above does not require the operator to read a string out of a
      sibling stack's output every apply. **Resolved as not-doing.**
      Conditional on option (2) (Kubernetes-provider automation), which
      was rejected in favour of option (1) (`kubectl create
      clusterrolebinding` documented in the README). With option (1)
      shipped, this variable would be dead code. Re-open only if option
      (2) is later chosen.

#### Cross-stack / tfvars

- [x] Update `gcp-management-tf/terraform.tfvars.example`,
      `aws-eks-tf/terraform.tfvars.example`, and
      `azure-aks-tf/terraform.tfvars.example` with the new
      cross-stack variables. **Done with caveats (Items 1/2/3/4).**
      Per-stack examples reflect the new variables they consume;
      however, a consolidated apply-order handoff comment (mgmt first
      → capture `service_account_unique_id` + `nat_public_ip` →
      paste into cluster stacks → apply → capture per-cluster outputs
      → paste back → re-apply mgmt) is not centralized in any single
      file. Minor follow-up: add the handoff narrative to the top of
      each example or to the root README.
- [x] Once item 5 (remote state) lands, replace that paste dance
      with `terraform_remote_state` data sources in each consumer
      stack. **Done as opt-in.** Added `aws_eks_states` /
      `azure_aks_states` map variables in `gcp-management-tf/variables.tf`,
      a new `gcp-management-tf/remote_states.tf` with `for_each`'d
      `data.terraform_remote_state.{aws_eks,azure_aks}` blocks
      (backends fixed to S3 + azurerm to mirror each cluster stack),
      and locals in `main.tf` that derive
      `aws_role_arns_effective` / `azure_federated_apps_effective`
      via `merge(from_state, explicit)`. The bootstrap template now
      jsonencodes the effective maps. Both new variables default to
      `{}`, so the legacy explicit-paste path still works unchanged
      and operators on local state are unaffected. Two-pass apply
      order documented in `gcp-management-tf/README.md`. Caveat:
      backend types are hard-coded — fleets storing cluster-stack
      state in non-S3 / non-azurerm backends still need the explicit
      maps.

### P0-sessions. Persistent kubectl sessions outlive a single refresh

**Status:** Complete with caveats. Implemented alongside Item 4 —
`/usr/local/sbin/mgmt-write-id-token`, `mgmt-gcp-id-token.service`+
`.timer` (50-min refresh cadence), `~/.aws/config` per-label profiles
with `web_identity_token_file`, `/etc/profile.d/mgmt-azure-federated.sh`
for kubelogin workloadidentity mode. Three blocking follow-ups tracked
in `P0 Item 4 — follow-up from implementation review` directly affect
this subsystem (RuntimeDirectory persistence, JWT leak via cmdline,
profile.d login-shell scope).

**Why it matters.** Item 4c's proposed `refresh-kubeconfigs` uses
`aws sts assume-role-with-web-identity` and caches the returned
credentials as **environment variables** inside the script's own
shell, and `az login --service-principal --federated-token`
followed by `az logout` at the end of the Azure loop. Both patterns
make credentials vanish the moment the refresh finishes:

- AWS STS web-identity credentials are short-lived (1h default, 12h
  max). When they expire mid-session, `kubectl` calls `aws eks
  get-token` under the hood and hits "no credentials" because the
  env vars that gave it credentials are gone.
- `az logout` at the tail of the Azure block wipes the `az account`
  cache; `kubelogin convert-kubeconfig -l azurecli` then has
  nothing to call at kubectl time.

The operator pattern is "SSH into mgmt VM, open k9s, leave it open
for a few hours." That needs credentials that refresh themselves,
not credentials that are fresh only for the first kubectl call.

**Proposed fix.** Two concurrent paths, one per cloud:

**AWS — `web_identity_token_file` credential profile.** Write the
GCP SA ID token to a file on disk and point an `~/.aws/config`
profile at it. The AWS SDK re-reads that file on every credential
refresh. Pair with a systemd timer that rewrites the file every 50
min (GCP ID tokens are valid 1h).

```ini
# ~/.aws/config (generated by the bootstrap, per label)
[profile mgmt-vm-<label>]
role_arn            = arn:aws:iam::<acct>:role/<name>-mgmt-vm
web_identity_token_file = /var/run/mgmt/gcp-id-token-aws
duration_seconds    = 3600
```

```bash
# /etc/systemd/system/mgmt-gcp-id-token.service — oneshot writer
# /etc/systemd/system/mgmt-gcp-id-token.timer   — OnUnitActiveSec=50min
```

**Azure — kubelogin `workloadidentity` mode.** `kubelogin
convert-kubeconfig -l workloadidentity` does not call `az` at token
time; it reads `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_CLIENT_ID`, and
`AZURE_TENANT_ID` from the environment and exchanges the federated
token itself. Wiring:

```bash
# /etc/profile.d/mgmt-azure-federated.sh (rendered by bootstrap)
export AZURE_FEDERATED_TOKEN_FILE=/var/run/mgmt/gcp-id-token-azure
export AZURE_CLIENT_ID=<from federated-principals.json>
export AZURE_TENANT_ID=<from federated-principals.json>
export AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

Same systemd timer rewrites the Azure audience token file every 50
minutes. `kubelogin -l workloadidentity` then Just Works for the
session lifetime.

**Replaces.** The env-var export pattern in item 4c's AWS block and
the `az login`/`az logout` pair in item 4c's Azure block. Item 4c's
*discovery* loop (list clusters, write kubeconfig entries) stays —
the change is only how the kubeconfig's auth stanzas reference
credentials, and how those credentials get kept fresh.

Tracked as a task under P0-checklist's "gcp-management-tf"
("Persistent-session wiring").

### P0-azsubs. Multi-subscription AKS discovery

**Status:** Complete with caveats. `azure_federated_apps` map entries
carry optional `subscription_ids`; the refresh script iterates with
`az account set --subscription` per entry and falls back to
`az account list` when unset. Robustness follow-up tracked in
`P0 Item 4 — follow-up from implementation review`: a failed
`az account set` for a subscription the SP can't see is
indistinguishable from "no AKS clusters" — typos in `subscription_ids`
produce silent empty discovery.

**Why it matters.** Item 4c calls `az aks list` once per configured
Azure label. That enumerates AKS clusters in the *currently
selected* subscription only. An operator with AKS labs in more than
one subscription (common: one per tenant, or separate "sandbox" vs
"shared" subs) will only see one of them.

**Proposed fix.** Extend `azure_federated_apps` map entries to
carry an optional `subscription_ids` list and have the refresh
script iterate:

```hcl
variable "azure_federated_apps" {
  type = map(object({
    client_id        = string
    tenant_id        = string
    subscription_ids = optional(list(string), [])
  }))
  default = {}
}
```

```bash
# in the Azure loop of refresh-kubeconfigs, after az login:
mapfile -t SUBS < <(jq -r ".azure_federated_apps[\"$label\"].subscription_ids[]?" "$CONFIG")
if [[ $${#SUBS[@]} -eq 0 ]]; then
  # fall back to whatever the federated login selected
  mapfile -t SUBS < <(az account list --query '[].id' -o tsv)
fi
for sub in "$${SUBS[@]}"; do
  az account set --subscription "$sub"
  mapfile -t ROWS < <(az aks list --query '[].{n:name,g:resourceGroup}' -o tsv)
  # ... existing per-cluster loop ...
done
```

Tracked as a task under P0-checklist's "gcp-management-tf"
(extend `azure_federated_apps` shape + refresh loop).

### P0 Item 1 — follow-up from implementation review

Correctness + robustness review of the landed cross-cloud federated
identity change. Blocking items must be fixed before the feature is
reliable; robustness items degrade under real-world conditions
(rotation, multi-env, destroy/re-apply, air-gapped CI).

- [x] **Blocking — AWS OIDC thumbprint uses the leaf cert, not the
      intermediate.** `aws-eks-tf/iam.tf:147` uses
      `data.tls_certificate.gcp_oidc[0].certificates[0].sha1_fingerprint`.
      `certificates[0]` is the *leaf* served by `accounts.google.com`,
      not the top intermediate/root. AWS historically documents the
      thumbprint as the SHA-1 of the *root CA* (or top-most cert in
      the chain). Google is on AWS's trusted root list so IAM
      currently ignores this value at token-validation time, but the
      field still has to be syntactically valid, and relying on "AWS
      ignores it for Google" is a latent footgun if that behaviour
      ever changes. Fix: index the last element of
      `certificates` (the chain closest to root, e.g.
      `certificates[length(certificates) - 1]`) or pin a known-good
      Google thumbprint and document the rotation runbook. At minimum,
      add a comment noting the current cosmetic status.
      Fixed: index changed to chain root (`length(certificates) - 1`)
      with inline comment.
- [x] **Blocking — `azuread` provider has no tenant pin.**
      `azure-aks-tf/providers.tf:26` declares `provider "azuread" {}`.
      Unlike azurerm (which takes `subscription_id` explicitly),
      azuread falls back to whatever tenant the ambient credential
      chain resolves first. On an operator workstation where `az
      login` has picked up a home tenant different from the one
      hosting the AKS subscription, the AAD App lands in the wrong
      tenant and the federated credential silently trusts the wrong
      issuer. Fix: add `tenant_id = data.azurerm_client_config.current.tenant_id`
      to the azuread provider block (the data source is already
      present and non-count-gated, so this works even when the
      feature is disabled).
      Fixed: `tenant_id` pinned to `data.azurerm_client_config.current.tenant_id`
      (data source declared in `iam.tf`, resolves cross-file).
- [x] **Robustness — IAM role name not unique across EKS stacks.**
      Resolved by documentation: `var.cluster_name` description in
      `aws-eks-tf/variables.tf` augmented to call out global-uniqueness
      within the AWS account because IAM role names are account-scoped.
      Auto-suffixing rejected because it would churn the role ARN
      across applies (and break access-entry references). The contract
      is now explicit in the variable description.
- [x] **Robustness — AAD App `display_name` not unique across
      subscriptions in same tenant.** Resolved by documentation:
      `var.cluster_name` description in `azure-aks-tf/variables.tf`
      augmented to call out tenant-uniqueness because the federated
      AAD App `display_name` derives from it. Same posture as the EKS
      sibling above.
- [x] **Robustness — `data.tls_certificate.gcp_oidc` re-resolved every
      plan when feature is enabled.** Resolved: added
      `var.gcp_oidc_thumbprint` (string, default `""`) to
      `aws-eks-tf/variables.tf` with 40-char hex validation. When
      non-empty, the data-source count-gate disables (no outbound TLS
      handshake) and `aws_iam_openid_connect_provider.gcp.thumbprint_list`
      uses the operator-pinned value via ternary. Air-gapped CI can
      pin the thumbprint and skip the plan-time TLS call entirely.
- [x] **Robustness — `mgmt_vm_tenant_id` output leaks tenant id when
      feature is disabled.** Resolved by Option (b): description in
      `azure-aks-tf/outputs.tf:73` rewritten as "current apply
      principal's tenant, for reference" with an explicit note that a
      non-null value does NOT imply federation is enabled. Output stays
      unconditional (tenant id is not secret); the misleading "federates
      into" framing is removed.
- [x] **Robustness — no `create_before_destroy` on the AAD App.**
      Resolved with full propagation through the chain: `lifecycle {
      create_before_destroy = true }` added to `azuread_application.mgmt_vm`,
      `azuread_service_principal.mgmt_vm`,
      `azuread_application_federated_identity_credential.mgmt_vm`, and
      `azurerm_role_assignment.mgmt_vm_aks_admin` in `azure-aks-tf/iam.tf`.
      First-pass implementation only set CBD on the parent App; reviewer
      surfaced that dependents reference ForceNew attributes of the App,
      so without CBD on each link Terraform would destroy the dependents
      before creating the new App and reopen the auth-gap. Comment block
      on the App's lifecycle now documents the propagation. Plan order
      on `cluster_name` rename is now create-new-App → SP → FedCred → RA
      → destroy-old-RA → FedCred → SP → App (no auth-gap window).
- [x] **Robustness — no explicit depends_on from
      `aws_eks_access_policy_association.mgmt_vm` to
      `aws_iam_role.mgmt_vm_federated`.** Resolved: `depends_on =
      [aws_iam_role.mgmt_vm_federated]` added to `aws_eks_access_entry.admin`
      in `aws-eks-tf/eks.tf:101-117` (the access-policy-association
      already has a depends_on to the access entry). Comment notes that
      with `count = 0` on the role, depends_on becomes a valid no-op.
- [x] **Robustness — `cluster_admin_principal_arn` coexistence path
      not tested.** Resolved: with Item 3's list-consolidation shipped
      and Item 1's separate `aws_eks_access_entry.mgmt_vm` absorbed
      into the list, the upgrade path is moot. `aws-eks-tf/README.md`
      now contains a 2026-04-27 paragraph at the top of the upgrade
      section confirming the list-driven path is the only active code
      path; operators starting fresh need no migration. Legacy
      `terraform state mv` recipe (with the new alternative `moved`
      block pattern from item 3) preserved for upgraders only.

### P0 Item 2 — follow-up from implementation review

Correctness + robustness review of the landed static-NAT-IP change.
Blocking items are misleading operator guidance; robustness items
affect destroy/re-apply ergonomics and multi-stack parallelism.

- [x] **Blocking — AUTO→MANUAL migration comment is wrong.**
      Resolved: comment block at `gcp-management-tf/modules/network/main.tf:55-61`
      rewritten to describe the actual provider 6.x behaviour — in-place
      update on the NAT (no `ForceNew`, no replacement), egress IP flips
      atomically at NAT config push, sub-second cutover with existing
      sessions persisting briefly via the NAT session table, and pointer
      noting the destroy footgun lives on `google_compute_address.nat`
      not on the NAT resource.
- [x] **Blocking — root `nat_public_ip` output description misleads
      when feature disabled.** Resolved: description at
      `gcp-management-tf/outputs.tf:37` reworded to scope the
      "append `<IP>/32` to authorized_cidrs" instruction to the
      `create_network = true` branch and to give BYO-network operators
      explicit guidance for the null case (query their own NAT/egress
      for the egress IP and feed it into authorized_cidrs the same way).
- [x] **Robustness — global name collision on
      `${var.name_prefix}-nat-ip`.** Resolved by documentation: added a
      `description` to `var.name_prefix` in
      `gcp-management-tf/modules/network/variables.tf` (previously had
      no description) covering the `google_compute_address`
      project+region uniqueness constraint and the IP-stability
      rationale that argues against auto-suffixing with `random_id`
      (which would churn the address name across applies, defeating
      the static-IP invariant from P0#2.4).
- [x] **Robustness — no `lifecycle { prevent_destroy }` on
      `google_compute_address.nat`.** Resolved: `prevent_destroy = true`
      added to the lifecycle block on `google_compute_address.nat` in
      `gcp-management-tf/modules/network/main.tf:41-69`. Comment block
      explains why this address is load-bearing (every cluster's
      `authorized_cidrs` references it) and documents the standard
      escape-hatch (comment out the lifecycle, apply, then destroy).
      **Caveat (P0#2.4 follow-up below):** the guard introduces friction
      for routine `terraform destroy` of the mgmt stack, which conflicts
      with the lab's "destroy when idle" operating principle. See item
      31 below.
- [x] **Robustness — reserved IP bills when detached.** Resolved:
      one-line note added inline with the prevent_destroy comment block
      at `gcp-management-tf/modules/network/main.tf` flagging the
      ~\$0.005/hr detached-IP charge so operators cleaning up a failed
      apply know to check.
- [x] **Robustness — EKS/AKS tfvars hint should steer to one
      canonical variable name.** Resolved: matching code comments
      added above each `variable "authorized_cidrs"` block in
      `aws-eks-tf/variables.tf`, `azure-aks-tf/variables.tf`, and
      `gcp-gke-tf/variables.tf`. Comments warn against renaming to
      mirror the cloud-native field name (e.g. azurerm's
      `api_server_authorized_ip_ranges`) so the cross-stack contract
      (referenced by `gcp-management-tf`'s `nat_public_ip` output
      description) stays stable. GKE's variant additionally documents
      its intentional shape difference (object-shaped vs flat list of
      strings).

### P0 Item 3 — follow-up from implementation review

Correctness + robustness review of the landed admin-list
consolidation. Blocking items produce a silently-broken mgmt VM or
stale operator guidance; robustness items degrade under non-default
workflows.

- [x] **Blocking — stack-local `aws-eks-tf/roadmap.md` still
      references the removed singular variable.** Resolved: both
      references in `aws-eks-tf/roadmap.md` (deployment-assumptions
      paragraph and the operator prerequisite) renamed to
      `cluster_admin_principal_arns`, phrased as a list, with the
      mgmt VM federated role ARN called out as the canonical second
      entry alongside the operator's IAM user/role ARN. Example value
      in the prerequisite updated from a bare ARN string to a list,
      with a note that the mgmt VM role ARN can be added either
      pre-computed or after first apply via `mgmt_vm_role_arn`.
- [x] **Robustness — silent-failure mode when operator uses the
      two-apply dance without the mgmt VM ARN.** Resolved:
      `aws-eks-tf/README.md` "Granting the mgmt VM cluster-admin"
      section restructured — pre-compute path promoted to default
      with explicit `aws sts get-caller-identity` recipe; two-apply
      path demoted to a footnote with explicit "kubectl returns
      forbidden until 2nd apply" warning. New default workflow
      eliminates the silent-failure window entirely.
- [x] **Robustness — ARN validation regex rejects non-commercial
      AWS partitions.** Resolved: regex in `aws-eks-tf/variables.tf`
      changed from `^arn:aws:iam::[0-9]{12}:(user|role)/` to
      `^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/`, accepting
      `aws-cn`, `aws-us-gov`, and other future partitions. Verified
      via terraform console smoke test against China and GovCloud
      ARN samples. Caveat (item 39 below): the looser regex also
      accepts trailing/double-dash typos like `aws-:` and `aws--cn:`
      — low-priority follow-up.
- [x] **Robustness — `toset()` silently dedupes duplicate ARNs.**
      Resolved: new validation block on
      `var.cluster_admin_principal_arns` in `aws-eks-tf/variables.tf`:
      `length(var.cluster_admin_principal_arns) ==
      length(toset(var.cluster_admin_principal_arns))` with error
      message "Duplicate ARN detected. Each principal must appear at
      most once." Verified via terraform console smoke test —
      duplicate ARN list rejected at validate time.
- [x] **Robustness — `moved` block omission is defensible but the
      README's rationale overstates the constraint.** Resolved:
      `aws-eks-tf/README.md` upgrade section now offers a per-operator
      literal `moved` block in a local-only `migrations.tf` as an
      alternative to `terraform state mv`, with a worked example and
      a note that the `moved` file should be deleted after apply
      succeeds. Strictly an additional pattern; the existing
      `terraform state mv` recipe stays as the simpler default.

### P0 Item 4 — follow-up from implementation review

Correctness + robustness review of the landed 4a+4b+4c + P0-sessions +
P0-azsubs change. Template escaping is clean (full `bash -n` passes on
the rendered script, no stray `$$`, jq and awk escapes survive). The
findings below are runtime behaviours `bash -n` cannot catch.

- [x] **Blocking — systemd `RuntimeDirectory=mgmt` on a `Type=oneshot`
      service deletes `/run/mgmt` (and the token files) the moment the
      oneshot exits.** Resolved by adding `RuntimeDirectoryPreserve=yes`
      to the `[Service]` block in `mgmt-gcp-id-token.service`
      (`bootstrap.sh.tpl:452`). Directory now survives oneshot exit, so
      `/var/run/mgmt/gcp-id-token-aws` and `/var/run/mgmt/gcp-id-token-azure`
      stay on disk between timer fires; AWS web_identity_token_file and
      Azure AZURE_FEDERATED_TOKEN_FILE refs no longer dangle.
- [x] **Blocking — `az login --federated-token "$(cat FILE)"` exposes
      the JWT in the process table.** Resolved by switching both call
      sites (main path `bootstrap.sh.tpl:937` and the new preflight
      handler `:731`) to `--federated-token-file "$AZ_TOKEN_FILE"`. The
      JWT now never appears on the command line, so it cannot be read
      from `/proc/<pid>/cmdline` by other local users. Comment notes the
      az CLI 2.62+ requirement (well below the packages.microsoft.com
      floor we install).
- [x] **Blocking — `/etc/profile.d/mgmt-azure-federated.sh` is only
      sourced by login shells, but `refresh-kubeconfigs`'s downstream
      kubectl/kubelogin path needs the env vars for
      workload-identity mode.** Resolved by adding an explicit
      `[[ -r /etc/profile.d/mgmt-azure-federated.sh ]] && . /etc/profile.d/mgmt-azure-federated.sh`
      at the top of the Azure block in `refresh-kubeconfigs`
      (`bootstrap.sh.tpl:912`) and inside `preflight_main`'s Azure
      branch. Header comment of the script now documents the sourcing
      requirement so cron/systemd/non-login `sudo` invocations get
      `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_FEDERATED_TOKEN_FILE`.
- [x] **Robustness — `kubelogin convert-kubeconfig -l workloadidentity`
      runs once at the end of the Azure block with no
      `--context`/`--kubeconfig-filter` scope.** Resolved: introduced
      `AZURE_CTXS=()` array in the refresh-kubeconfigs Azure block,
      pushed each successfully-merged AKS context name
      (`azure-${label}-${name}`) into it inside the `az aks
      get-credentials` inner loop, then iterate the array and call
      `kubelogin convert-kubeconfig -l workloadidentity --context
      "$ctx"` per-entry. Verified `--context` is the real flag
      (`pkg/internal/converter/options.go: flagContext = "context"`).
      The previous unscoped one-shot call is gone. Comment block in
      `bootstrap.sh.tpl` documents the defence-in-depth rationale.
- [x] **Robustness — `AZ_FIRST_CLIENT_ID` / `AZ_FIRST_TENANT_ID`
      default to empty strings when `azure_federated_apps` is `{}`.**
      `gcp-management-tf/scripts/bootstrap.sh.tpl:530-532, 540-541`.
      jq's `(.[0].value.client_id // "")` on an empty array returns
      `""`, and the profile.d script ends up exporting
      `AZURE_CLIENT_ID=''` / `AZURE_TENANT_ID=''`. If an operator later
      adds an AKS context by hand before the next mgmt apply,
      kubelogin's workloadidentity mode dies with a
      client_id-is-empty error. Fix: guard the whole block on
      `[[ "$AZ_LABEL_COUNT" -gt 0 ]]` — when zero apps are
      configured, skip writing profile.d entirely (or write only the
      token-file + authority-host lines and a comment). **Done.**
      Wrapped the entire profile.d-emit block in
      `if [[ "$AZ_LABEL_COUNT" -gt 0 ]]; then ... else rm -f $AZURE_PROFILE_D; fi`
      so zero-app installs leave no stale empty exports in operator
      shells (and any prior file from a previous apply is removed),
      letting kubelogin surface its own client_id-required diagnostic.
- [x] **Robustness — `PERSONA_GROUP` expansion in the systemd unit
      heredoc has no fallback if `id -gn` fails.**
      `gcp-management-tf/scripts/bootstrap.sh.tpl:373, 444-455`.
      `<<SERVICE` is unquoted so `Group=${PERSONA_GROUP}` is expanded
      at bootstrap time; if `id -gn "$VM_USER"` returns empty (user
      creation hiccup, NSS timing, bootstrap re-run before user
      exists), the unit lands with `Group=`, systemd's load fails, and
      subsequent `systemctl start` reports a cryptic parse error. Fix:
      `: "${PERSONA_GROUP:?persona group unresolved — phase 6 must run before phase 8}"`
      guard before the heredoc, and/or add the guard at the top of
      phase 8. **Done.** Added the `${VAR:?msg}` guard immediately
      after the `PERSONA_GROUP="$(id -gn ...)"` assignment in phase 8
      AND defensively re-guarded right before the unquoted `<<SERVICE`
      heredoc so the failure mode is loud and early at either site.
      The bash idiom aborts the script with a clear "phase 6 (user
      creation) ran before phase 8 (federation)" message instead of
      letting an empty `Group=` reach systemd.
- [x] **Robustness — `az account set --subscription` for a sub the
      federated SP cannot see fails hard and the whole label's
      remaining subs are skipped.** Resolved (runtime diagnostic only):
      `bootstrap.sh.tpl` now emits `"  !! subscription $sub not
      accessible to $label (typo or missing role assignment) —
      skipping"` before the `continue`, distinguishing "sub typo /
      missing role" from "this sub has no AKS clusters." Behaviour
      unchanged (still continues to the next sub). **Caveat:** the
      proposed apply-time preflight against `az account list` is NOT
      implemented — see new item 32 below.
- [x] **Robustness — GKE context rename collides for multi-location
      clusters with the same name.**
      `gcp-management-tf/scripts/bootstrap.sh.tpl:633-634`. Rename
      target is `gke-${proj}-${name}` — location is dropped. Two
      clusters named `lab` in the same project, one in `us-central1`
      and one in `us-east1-a`, rename to the same context and the
      second overwrites the first. Unlikely in a tiny lab but the
      original gcloud form `gke_${proj}_${loc}_${name}` was
      collision-proof; the rename is strictly lossier. Fix: include
      location in the alias (`gke-${proj}-${loc}-${name}`) or only
      rename when a duplicate name across locations is absent
      (`kubectl config get-contexts` check first). **Done.** Changed
      `new_ctx` to `gke-$${proj}-$${loc}-$${name}` to mirror the
      collision-proof shape of gcloud's original
      `gke_<proj>_<loc>_<name>`. The location was already extracted
      one line earlier from `gcloud container clusters list
      --format='value(name,location)'` so no upstream walk-back was
      needed. Updated the `refresh-kubeconfigs` header comment to
      document the new `gke-<project>-<location>-<cluster>` shape.
- [x] **Robustness — `AWS_PROFILE` region default `us-east-1` in
      `~/.aws/config` hides multi-region intent from ad-hoc operator
      commands.** `gcp-management-tf/scripts/bootstrap.sh.tpl:514`.
      The comment at :499-502 acknowledges this; the UX consequence is
      an operator who types `aws --profile mgmt-vm-foo eks
      list-clusters` (no `--region`) quietly scans only us-east-1 and
      thinks the west clusters are gone. Fix: either omit the `region`
      line from each profile entirely (forces explicit `--region`) or
      default to the first entry of `var.aws_regions` rather than a
      hard-coded `us-east-1`. **Done.** Chose option (a): dropped the
      `region = us-east-1` line from each `[profile mgmt-vm-<label>]`
      entry and replaced the in-template comment with a one-line
      profile-header note (`# region intentionally unset — supply
      --region explicitly to avoid silent us-east-1-only scans`).
      `refresh-kubeconfigs` already passes `--region` explicitly when
      iterating `var.aws_regions`, so the loop is unaffected; ad-hoc
      `aws --profile mgmt-vm-foo eks list-clusters` now errors
      cleanly with `You must specify a region` instead of silently
      scanning a single hard-coded region.

### P0 Item 5 — follow-up from implementation review

Correctness + robustness review of the landed remote-state bootstrap
stacks + sibling backend wiring. `terraform fmt -check -recursive`
passes across `bootstrap-state/` and every `backend.tf`. The bootstrap
designs are sound; findings below are traps that only surface at
`init`/`apply` or `destroy` time.

- [x] **Blocking — `use_lockfile = true` in
      `aws-eks-tf/backend.hcl.example:10` silently fails on Terraform
      < 1.10, but `aws-eks-tf/versions.tf:2` still allows `>= 1.5.0`.**
      An operator on 1.5-1.9 (inside the declared floor) uncomments
      `backend.tf`, copies the example, runs `init -migrate-state`,
      and gets an `unknown argument "use_lockfile"` error at best or a
      writer-race at worst. The `bootstrap-state/aws/README.md:34-37`
      note is insufficient — the required_version must enforce the
      floor. Fix: bump `aws-eks-tf/versions.tf` (and any future AWS
      sibling) to `required_version = ">= 1.10.0, < 2.0.0"`. Same bump
      belongs on `bootstrap-state/aws/versions.tf:2` — the bootstrap
      itself does not need 1.10, but homogenising the floor prevents
      the operator from apply-ing bootstrap on 1.9 then discovering
      the sibling cannot migrate. **Done.** Both `aws-eks-tf/versions.tf`
      and `bootstrap-state/aws/versions.tf` bumped to
      `>= 1.10.0, < 2.0.0`; rationale comments inline at each pin.
- [x] **Blocking — `bootstrap-state/aws/main.tf:22-26` creates the
      tfstate CMK with no explicit key policy, so S3 backend callers
      without a separate IAM grant to `kms:Decrypt` /
      `kms:GenerateDataKey` fail the first `plan` against the
      bucket.** Default KMS key policy only grants root-of-account
      admin; IAM policies on the operator principal must then allow
      the KMS actions, or an explicit key policy statement must grant
      them. Most lab operators run with `AdministratorAccess` and
      won't notice — but anyone scoped down (the stated "least-
      privilege" posture this repo preaches) will hit `AccessDenied`
      on `GenerateDataKey` at state write. Fix: either attach an
      explicit `aws_kms_key_policy` granting the caller's ARN the four
      actions `kms:Encrypt` / `kms:Decrypt` / `kms:GenerateDataKey` /
      `kms:DescribeKey`, or document the IAM grant requirement
      prominently in `bootstrap-state/aws/README.md` (currently
      buried in one sentence at line 23-25 of `outputs.tf`, absent
      from the README's "Apply" section). **Done.** Added
      `data "aws_caller_identity" "current"` plus
      `aws_kms_key_policy.tfstate` with two statements: `RootAdmin`
      (account root, `kms:*`) and `OperatorStateAccess` (caller ARN,
      the four data-plane actions). README updated with a "KMS key
      policy" section.
- [x] **Blocking (high-severity robustness) — no `prevent_destroy`
      lifecycle on the state buckets or Azure container / storage
      account.** `bootstrap-state/gcp/main.tf:13`,
      `bootstrap-state/aws/main.tf:37`,
      `bootstrap-state/azure/main.tf:16,41`. `force_destroy = false`
      (AWS/GCP) prevents destroy *while objects exist*, but an
      operator who runs `terraform destroy` in a bootstrap stack
      after having manually emptied the bucket — or on Azure, where
      no force_destroy exists and destroy happily wipes a non-empty
      storage account — nukes every sibling stack's state. Azure is
      the worst: `azurerm_storage_account` deletes the account
      (taking all containers + blobs) without a guard. Fix: add
      `lifecycle { prevent_destroy = true }` to
      `google_storage_bucket.tfstate`, `aws_s3_bucket.tfstate`,
      `aws_kms_key.tfstate` (losing the CMK strands the ciphertext),
      and `azurerm_storage_account.tfstate` +
      `azurerm_storage_container.tfstate`. Document the escape hatch
      (comment out the lifecycle + re-apply) in each bootstrap README.
      **Done.** `prevent_destroy = true` added to all five resources
      (GCS bucket, S3 bucket, KMS CMK, Azure storage account, Azure
      container) with the standard escape-hatch comment. Teardown
      sections of all three bootstrap READMEs updated with the
      comment-out-then-apply procedure.
- [x] **Robustness — `bootstrap-state/gcp/README.md:30-31` claims the
      GCS backend "locks natively via the generation-checked lock
      object"; this overstates the guarantee.** GCS's Terraform
      backend uses an advisory lock file (`default.tflock`) with
      conditional writes — it is racy against `force-unlock` and
      against clients that skip the lock entirely. For a single-
      operator lab it is fine, but the wording implies equivalence
      with DynamoDB / S3-lockfile guarantees. Fix: soften to
      "advisory lock object with generation-checked writes; adequate
      for sequential operators, not a distributed mutex." Same
      softening applies to `gcp-management-tf/backend.tf:10-11` and
      `gcp-gke-tf/backend.tf:10-11`. **Done.** Wording softened at
      all three sites (bootstrap-state/gcp/README.md,
      gcp-management-tf/backend.tf, gcp-gke-tf/backend.tf).
- [x] **Robustness — `bootstrap-state/azure/main.tf:16-39` has no
      `prevent_destroy` AND Azure storage account deletion is
      irreversible after the soft-delete retention window.** Even
      with the lifecycle guard above, the default storage-account
      soft-delete policy is not configured here — a recovered
      destroy within 7 days is possible only if the subscription's
      default retention covers it. Fix: set
      `blob_properties.delete_retention_policy.days = 30` and
      `container_delete_retention_policy.days = 30` on the storage
      account; cheap insurance for state recovery. **Done.** Both
      retention blocks added inside the existing `blob_properties`
      block on `azurerm_storage_account.tfstate`, set to 30 days
      each.
- [x] **Robustness — `bootstrap-state/aws/README.md:49-51` claims
      "The bucket ships without `force_destroy`, so `terraform
      destroy` fails while any sibling stack still stores state in
      it."** True, but the README does not mention that
      `aws_kms_key.tfstate` has `deletion_window_in_days = 7` and
      *will* be scheduled for deletion on destroy — a destroy that
      succeeds after the operator manually empties the bucket takes
      the CMK with it, rendering any surviving ciphertext
      (e.g. point-in-time copies, CloudTrail log entries encrypted by
      it) permanently unreadable. Fix: call out the CMK deletion
      behaviour in the teardown section and recommend
      `aws kms disable-key` + manual deletion via console after a
      cooling-off period instead of `terraform destroy`. **Done.**
      Teardown section now flags the irreversible 7-day window and
      recommends `aws kms disable-key` + manual console deletion.
- [x] **Robustness — `bootstrap-state/azure/README.md:35-48` documents
      the `operator_principal_id` path but the "out-of-band" example
      at line 42-47 builds the scope string manually with
      `/blobServices/default/containers/tfstate` appended to the
      storage-account ID.** That scope form works but is not the
      `resource_manager_id` the in-stack role assignment uses (line
      59 of `main.tf`). The two paths grant the same role at
      effectively the same scope, but the README form is fragile to
      container rename (hardcoded `tfstate`). Fix: have the README
      suggest `$(terraform output -raw container_resource_id)` after
      adding a `container_resource_id` output to the bootstrap —
      currently `outputs.tf` exposes no such output, so the README's
      `terraform output -raw container_resource_id 2>/dev/null || ...`
      fallback always takes the `||` path silently. **Done.** Added
      `container_resource_id` output to `bootstrap-state/azure/outputs.tf`
      (sourced from `azurerm_storage_container.tfstate.resource_manager_id`)
      and simplified the README example to use it directly.
- [x] **Robustness — `.gitignore` pattern for `backend.hcl` is
      shadowed by the earlier `*.tfvars` / wildcard rules only if the
      operator names a backend file `backend.tfvars`; the current
      `backend.hcl` + `!backend.hcl.example` pair works as intended.**
      Verified by reading `.gitignore`: `*.tfstate*` and `*.tfvars*`
      rules do not intersect `backend.hcl`, and the negation on the
      same pattern group fires correctly. No change needed — noting
      here so the review record shows the check was done.
- [x] **Robustness — `aws-eks-tf/backend.hcl.example:9` ships an ARN
      with `REPLACE-ME` account + key ID.** That is the right
      posture, but the file is committed (the negation in
      `.gitignore` keeps it tracked). If an operator edits the
      committed `.example` in-place instead of copying to
      `backend.hcl`, their account ID leaks on the next `git add`.
      Fix: add a prominent header comment (`# DO NOT EDIT — copy to
      backend.hcl first`) to each `.example` file. Current headers
      say "Copy to backend.hcl" but not "do not edit here." **Done.**
      `# DO NOT EDIT THIS FILE — copy to backend.hcl first, then fill
      in values there.` prepended to all four committed
      `backend.hcl.example` templates (aws-eks-tf, azure-aks-tf,
      gcp-gke-tf, gcp-management-tf).

---

## P1 — Genuinely-bug items independent of the mgmt VM arc

### 6. EKS node group has no Spot fallback instance types

**Why it matters.** `aws-eks-tf/eks.tf:214` hard-codes
`instance_types = [var.node_instance_type]`. Spot capacity is
allocated per-instance-type per-AZ; at 2 nodes in 2 AZs a single
type hitting zero Spot supply means the lab sits cold. Diversifying
across 2–3 similar sizes meaningfully improves fill rate at zero
on-demand premium.

That said: with only 2 nodes and a "cluster may be down half the
day" posture, a cold Spot fleet is an inconvenience rather than an
outage. This is P1 not P0 because a lab can tolerate "try again in
5 minutes" whereas it cannot tolerate "can't kubectl at all."

**Proposed fix.**

```hcl
# aws-eks-tf/variables.tf — new
variable "spot_instance_types" {
  description = "Instance types offered to the Spot fleet. Diversified list (t3.small / t3a.small / t2.small) improves fill rate; single-family ~2 GiB options mean consistent scheduling. Only consulted when use_spot_instances = true."
  type        = list(string)
  default     = ["t3.small", "t3a.small", "t2.small"]
}

# aws-eks-tf/eks.tf — replace the instance_types line in
# aws_eks_node_group.primary
instance_types = var.use_spot_instances ? var.spot_instance_types : [var.node_instance_type]
```

**Status:** Done. spot_instance_types variable added with t3/t3a/t2.small default; instance_types in node group switches on use_spot_instances.

### 7. EKS "additional" security groups are empty dead code

**Why it matters.** `aws_security_group.cluster` at
`aws-eks-tf/eks.tf:43-51` is attached to the control plane ENIs
with zero rules. `aws_security_group.nodes` at
`aws-eks-tf/eks.tf:131-140` is not referenced anywhere. Both add
state + review surface for no benefit.

**Proposed fix.** Delete both. They can be added back in one commit
when a real rule exists. The managed EKS SGs handle all required
traffic for the current topology.

```hcl
# aws-eks-tf/eks.tf — remove
#   resource "aws_security_group" "cluster"   { ... }
#   resource "aws_security_group" "nodes"     { ... }
# and drop `security_group_ids = [aws_security_group.cluster.id]`
# from aws_eks_cluster.this.vpc_config.
```

**Status:** Done. Both SGs deleted; aws_eks_cluster.this.vpc_config no longer references them.

### 8. Output naming drift across cluster stacks

**Status:** Done. EKS `cluster_region` renamed to `cluster_location`
(see `aws-eks-tf/outputs.tf`), AKS `location` renamed to
`cluster_location` (see `azure-aks-tf/outputs.tf`), GKE was already
`cluster_location` and is unchanged. EKS gained a sibling
`nat_gateway_public_ips` output (list, one per AZ unless
`single_nat_gateway = true`) mirroring AKS's `nat_gateway_public_ip`
(singular). No backwards-compat aliases were added — there were no
internal consumers of the old names. The GCP/mgmt-tf cross-stack
section now consumes these via opt-in `terraform_remote_state` data
sources (see Cross-stack / tfvars checklist above).

**Why it mattered.** The mgmt VM's `refresh-kubeconfigs` (item 4)
will read outputs from each cluster stack's remote state. Keeping
the shape consistent means one parser, not three. Pre-rename:

| Output | GKE | EKS | AKS |
|--------|-----|-----|-----|
| Location/region | `cluster_location` | `cluster_region` | `location` |
| Cluster egress IP | (Cloud NAT pool, not exposed) | (not exposed) | `nat_gateway_public_ip` |
| Kubeconfig helper | `kubectl_configure_command` | `kubectl_configure_command` | `kubectl_configure_command` |

**Proposed fix.** Rename to `cluster_location` on EKS + AKS:

```hcl
# aws-eks-tf/outputs.tf — rename
output "cluster_location" {
  description = "AWS region the cluster lives in."
  value       = var.region
}

# azure-aks-tf/outputs.tf — rename (keep the sibling symmetry)
output "cluster_location" {
  description = "Azure region the cluster lives in."
  value       = azurerm_resource_group.this.location
}
```

Add an egress-IP output to EKS for symmetry with AKS
(`nat_gateway_public_ip`):

```hcl
# aws-eks-tf/outputs.tf — new
output "nat_gateway_public_ips" {
  description = "Public IP(s) of the NAT Gateway(s). Egress source IP(s) seen by external services."
  value       = aws_eip.nat[*].public_ip
}
```

(Verify actual resource name in `aws-eks-tf/network.tf` before
copying.)

### 9. Provider version drift inside `gcp-management-tf`

**Why it matters.** The root `gcp-management-tf/versions.tf` pins
`google ~> 6.10` with `required_version = >= 1.5.0` (no upper
bound). Each of `gcp-management-tf/modules/{iam,network,mgmt-vm}/
versions.tf` separately pins `google ~> 6.10`. On any future minor
bump, all four files must change in lockstep.

`gcp-gke-tf` pins `google ~> 6.12`, so the two GCP stacks pull
different provider binaries today.

**Proposed fix.**

1. Add `< 2.0.0` to `gcp-management-tf/versions.tf` `required_version`.
2. Bump `gcp-management-tf` root pin to `~> 6.12` to match
   `gcp-gke-tf`.
3. Delete `versions.tf` in each submodule that only uses `google`
   — Terraform inherits from the root. Keep a submodule-level
   `required_providers` block only if that submodule uses a provider
   the root does not.

```hcl
# gcp-management-tf/versions.tf
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

Run `terraform init -upgrade` after to refresh
`.terraform.lock.hcl`.

**Status:** Done. Root pin bumped to ~> 6.12 with upper-bound required_version (>= 1.5.0, < 2.0.0); submodule versions.tf files deleted (modules/iam, modules/network, modules/mgmt-vm — all only used the google provider, which is inherited from root). .terraform.lock.hcl regenerated; constraints now show ~> 6.12 / ~> 6.12 / ~> 3.6.

### 10. CIDR allocation is undocumented

**Why it matters.** Lightweight item but becomes load-bearing the
moment anyone tries to VPC-peer the mgmt VM's VPC with a cluster's
VPC (for "truly private" control plane access) or spin up a second
cluster in any cloud.

**Current allocation.**

| Stack | Primary /16 | Secondary / sub-ranges |
|-------|-------------|------------------------|
| `gcp-management-tf` | `10.10.0.0/16` | subnet `10.10.0.0/24` |
| `gcp-gke-tf`        | — (subnet-mode) | nodes `10.20.0.0/24`, pods `10.21.0.0/16`, svc `10.22.0.0/20`, master `172.16.0.0/28` |
| `aws-eks-tf`        | `10.30.0.0/16` | /20 per AZ from the /16 |
| `azure-aks-tf`      | `10.40.0.0/16` | subnet `10.40.0.0/20`, pods `10.244.0.0/16`, svc `10.41.0.0/16` |

**Proposed fix.** New `/home/n/cloud-lab/CIDRS.md`:

```markdown
# cloud-lab CIDR allocation

One lab per cloud assumed. If a second lab is needed, pick from the
"reserved" column.

| Stack | Primary | Secondary | Reserved for second-lab |
|-------|---------|-----------|--------------------------|
| gcp-management-tf | 10.10.0.0/16 | — | 10.11.0.0/16 |
| gcp-gke-tf        | (subnet-mode) 10.20.0.0/24 | 10.21.0.0/16 pods, 10.22.0.0/20 svc, 172.16.0.0/28 master | 10.23-29 |
| aws-eks-tf        | 10.30.0.0/16 | — | 10.31-39 |
| azure-aks-tf      | 10.40.0.0/16 | 10.244.0.0/16 pods, 10.41.0.0/16 svc | 10.42-49 |

AKS pod_cidr uses 10.244.0.0/16 by Kubernetes convention.
GKE master_ipv4 uses 172.16.0.0/28 because the master peering VPC
is outside the user VPC.
EKS VPC CNI uses VPC primary IPs for pods (no separate range).
```

**Status:** Done. CIDRS.md written at repo root with the verified allocations.

### 18. `terraform_remote_state` data sources hard-code `s3` and `azurerm` backends

**Why it matters.** The cross-stack remote-state wiring landed in
`gcp-management-tf/remote_states.tf` (P0-checklist Cross-stack
`terraform_remote_state` item) declares `backend = "s3"` for
`data.terraform_remote_state.aws_eks` and `backend = "azurerm"` for
`data.terraform_remote_state.azure_aks`. Terraform does not allow the
`backend` field to be a variable — it is parsed before variable
evaluation. Operators storing cluster-stack state in non-S3 / non-azurerm
backends (e.g. an AWS stack with state in GCS, or an air-gapped lab
with HTTP backend) cannot use the remote-state path; they fall back to
the explicit `aws_role_arns` / `azure_federated_apps` paste-dance.

For the lab's intended workflow (`bootstrap-state/<cloud>/` per cloud)
this is fine — siblings ship matching-cloud backends. But a future
"single-cloud lab" or "shared backend across clouds" topology would
need this loosened.

**Proposed fix (only when the constraint actually bites).** Either:

- Add parallel `data "terraform_remote_state"` blocks gated on a
  variable `aws_eks_state_backend` (default `"s3"`, also accepts
  `"gcs"`, `"local"`, etc.), with one block per supported backend and
  a `merge()` over all of them. Verbose but explicit.
- Replace the `terraform_remote_state` path with a custom data source
  fetching outputs via `terraform output -json` over SSH or a
  Cloud Function. Strictly worse for this lab.

Documented in `gcp-management-tf/remote_states.tf` header and in
`gcp-management-tf/variables.tf` description for `aws_eks_states` /
`azure_aks_states`.

### 19. `azurerm_kubernetes_cluster_maintenance_configuration` not in installed azurerm version

**Status:** Done. Resolved by Option B — deleted the
`azurerm_kubernetes_cluster_maintenance_configuration "default"`
block (and its preceding comment near line 161 in `aks.tf`) rather
than bumping the provider pin to chase a non-goal feature. Now
consistent with P2 item 13 ("Maintenance window alignment — NOT
DOING"): clusters in this lab are routinely destroyed when idle, so
a recurring weekly maintenance window has no purpose. While
validating the fix, a latent rename also surfaced in the same file
(`network_dataplane` -> `network_data_plane` on the
`network_profile` block) and was corrected so `terraform validate`
returns green. Validate now passes with one unrelated deprecation
warning on `azurerm_monitor_diagnostic_setting.metric` (slated for
removal in azurerm v5.0; tracked separately).

**Why it matters.** `terraform validate` against `azure-aks-tf/`
fails with an unknown-resource error on
`azurerm_kubernetes_cluster_maintenance_configuration`. Surfaced
during the P0 hardening pass (running `terraform fmt -recursive`
followed by `validate` to confirm the rename + tenant-pin fixes
clean). Pre-existing on the working tree — not introduced by the
P0 implementation or the hardening agents. The pinned `azurerm`
version in `azure-aks-tf/versions.tf` predates that resource type
landing in the provider, OR the resource name has been renamed
upstream and the pin needs bumping.

**Status:** Done. Resolved by Option B — deleted the
`azurerm_kubernetes_cluster_maintenance_configuration "default"` resource
from `azure-aks-tf/aks.tf` (consistent with P2#13: maintenance window
alignment is a non-goal for this lab; clusters are routinely destroyed
when idle). Also fixed a latent `network_dataplane` → `network_data_plane`
rename surfaced by validate. `terraform validate` now passes (one
unrelated `metric` block deprecation warning tracked as item 20 below).

**Proposed fix (deferred — see Status above).** Cross-reference
`azure-aks-tf/aks.tf` for the exact resource block, check the `azurerm`
provider changelog for when `azurerm_kubernetes_cluster_maintenance_configuration`
(or its renamed equivalent — `automatic_channel_upgrade` ⇒
`maintenance_window` shapes have churned) actually shipped, then either
bump the pin in `versions.tf` or rewrite the resource to whatever shape
the current pin supports. Test with `terraform validate` post-change.

### 20. `azurerm_monitor_diagnostic_setting.aks` uses deprecated `metric` block

**Status:** Done. metric block replaced with enabled_metric; deprecation warning cleared on validate.

**Why it matters.** `azure-aks-tf/aks.tf:229-232` declares a
`metric { category = "AllMetrics" enabled = true }` block. The current
azurerm pin (`~> 4.14`, lock at `4.70.0`) emits a deprecation warning
on every `validate`/`plan`: `metric has been deprecated in favour of
the enabled_metric property and will be removed in v5.0 of the AzureRM
provider`. Confirmed against the provider source — the `metric` schema
is gated on `!features.FivePointOh()` and `ConflictsWith =
["enabled_metric"]`. When the next major (`v5.0`) lands, this stack
will fail `validate` outright until the block is replaced.

**Proposed fix.** Replace the deprecated block with the new shape. No
`enabled` field — presence in the new schema implies enabled.

```hcl
# azure-aks-tf/aks.tf — replace the metric block
enabled_metric {
  category = "AllMetrics"
}
```

`AllMetrics` was the only valid category here, so no behavioural
change. Verify post-change with `terraform validate` (warning should
clear) and `terraform plan` (should show in-place update on the
diagnostic setting, no recreate).

### 21. `init -upgrade` does not always rewrite `.terraform.lock.hcl` constraints — operator gotcha

**Status:** Done. Documented in gcp-management-tf/README.md (and mirrored in any sibling stacks with provider-pin sections); workflow note covers init -upgrade + lock-file edge case.

**Why it matters.** When bumping a provider pin in `versions.tf`
(e.g. the `~> 6.10` → `~> 6.12` bump in item 9), the standard
incantation `terraform init -upgrade` is supposed to refresh the lock
file. In practice: if the previously-resolved provider version *also*
satisfies the new constraint (e.g. `6.50.0` satisfies both `~> 6.10`
and `~> 6.12`), Terraform sees no work to do, **skips the lock file
rewrite**, and the `constraints = "~> 6.10"` line silently survives
the bump. Future operators reading the lock file see a constraint
that doesn't match the source-of-truth `.tf` declaration. CI
lockfile-drift checks fail spuriously.

**Proposed fix (operator workflow note, not code).** Document in
`gcp-management-tf/README.md` and any other stack README with a
provider pin: when bumping a major-minor pin, run `rm
.terraform.lock.hcl && terraform init -upgrade` instead of plain
`init -upgrade`. (Removing `.terraform/` alone is insufficient —
Terraform reuses cached resolution data.) Optional: add a `make
refresh-lock` Makefile target across stacks that does this atomically.

### 22. Doc-drift cleanup from P1 pass — stale references to deleted resources

**Status:** Done. All 6 doc-drift sites resolved; verbatim references updated per review report Section B.

**Why it matters.** Several docs survived the P1 deletions referenced
in items 7 and 19 with stale claims that point operators at resources
that no longer exist:

1. `aws-eks-tf/README.md:133` — `> Optionally, tighten the
   ${cluster_name}-nodes-sg security group for east-west traffic.`
   That SG was deleted in P1#7.
2. `aws-eks-tf/README.md:117` — OOM-recovery advice says "bump
   `node_instance_type` to `t3.medium`". With the default
   `use_spot_instances = true`, that variable is now ignored (the
   Spot path uses `spot_instance_types`).
3. `azure-aks-tf/README.md:16` — Lists "Weekly Saturday 06:00-10:00
   UTC maintenance window" as a feature. Resource deleted in P1#19.
4. `azure-aks-tf/roadmap.md:68` — `- [x] Separate
   maintenance_configuration — Saturday 06:00-10:00 UTC` checkbox is
   checked but the resource no longer exists.
5. `azure-aks-tf/aks.tf:71` — Comment text `network_dataplane =
   "cilium"` (prose) inconsistent with the corrected arg
   `network_data_plane` one line down at `:83`.
6. `proj_roadmap.md` `### 10.` "Current allocation" table — claims
   `/19 per AZ from the /16` for `aws-eks-tf`; actual code at
   `aws-eks-tf/network.tf:20-21` (`cidrsubnet(var.vpc_cidr, 4, i)`)
   produces `/20`. CIDRS.md has it right; this row pre-dates the P1
   pass and was missed.

**Proposed fix.** Single doc-pass touching the six sites above. None
affect runtime behaviour — purely review-surface drift. Mechanical
edits per site listed inline.

### 23. `node_instance_type` description should cross-reference Spot

**Status:** Done. Description appended; Spot/non-Spot path now symmetric across both vars.

**Why it matters.** `aws-eks-tf/variables.tf:27-31` describes
`node_instance_type` without noting that it's only used when
`use_spot_instances = false`. The sibling variable `spot_instance_types`
correctly cross-references back ("on-demand uses var.node_instance_type").
The asymmetry will mislead operators who edit `node_instance_type`
while Spot is on, plan, and see no diff.

**Proposed fix.** Append one sentence to the description:

```hcl
variable "node_instance_type" {
  description = "EC2 instance type for the managed node group. t3.small = 2 vCPU / 2 GiB, the closest analog to GCP e2-small. Adequate for a typical EDR agent DaemonSet (~500m CPU / 512 Mi–1 GiB memory) plus a few lightweight lab pods. Only consulted when use_spot_instances = false; otherwise see spot_instance_types."
  type        = string
  default     = "t3.small"
}
```

### 24. `azurerm_storage_container.resource_manager_id` is deprecated in azurerm ~> 4.14

**Status:** Done. Both call sites
(`bootstrap-state/azure/outputs.tf` `container_resource_id` output and
`bootstrap-state/azure/main.tf` `azurerm_role_assignment.operator_blob_contributor.scope`)
now use the explicit ARM-ID interpolation
`"${azurerm_storage_account.tfstate.id}/blobServices/default/containers/${azurerm_storage_container.tfstate.name}"`.
`terraform validate` on `bootstrap-state/azure/` passes with zero
deprecation warnings (was 2). Functional behaviour identical — the
interpolation is byte-equivalent to what `resource_manager_id` emitted.

**Why it matters.** `bootstrap-state/azure/outputs.tf:18`
(`container_resource_id`) and `bootstrap-state/azure/main.tf:86`
(role-assignment `scope`) both reference
`azurerm_storage_container.tfstate.resource_manager_id`. Provider
schema flags it `deprecated=True` (verified via `terraform providers
schema -json` against azurerm 4.70.0). `terraform validate` on
`bootstrap-state/azure/` now emits two deprecation warnings — exactly
the noise Item 20 just cleared in `azure-aks-tf/`. The new output
introduced by P0 Item 5c hardening propagated an existing latent
deprecation rather than introducing a new one — the role-assignment
scope already used it.

`azurerm_storage_container.id` returns the data-plane URL
(`https://<acct>.blob.core.windows.net/<container>`), not the ARM
resource ID, so it cannot be a drop-in replacement. The canonical
ARM-scope shape is:

    "${azurerm_storage_account.tfstate.id}/blobServices/default/containers/${azurerm_storage_container.tfstate.name}"

This is what `resource_manager_id` returns under the hood and is the
right migration target until azurerm exposes a successor attribute
(`resource_id` / `arm_id`) in a future minor.

**Proposed fix.** Replace both call sites with explicit ARM-ID
construction via interpolation, in a single PR. `terraform validate`
on `bootstrap-state/azure/` should emit zero warnings post-change.
Functional behaviour identical (the resulting ARM-ID string is
byte-identical to what `resource_manager_id` emitted); apply produces
no diff.

### 25. `AZ_LABEL_COUNT` jq arithmetic — defensive `// 0` and `|| echo 0`

**Status:** Done. Defensive triple-guard pattern (`(.x | length) // 0`
inside jq, `2>/dev/null || echo 0` shell fallback, `${VAR:-0}` arithmetic
guard) applied at all five `jq | length` arithmetic sites in
`gcp-management-tf/scripts/bootstrap.sh.tpl`: `AZ_LABEL_COUNT` (the
flagged primary site), `aws_count` and `az_count` in preflight,
`AWS_LABELS_COUNT` and `AZ_LABELS_COUNT` in refresh-kubeconfigs.
Manually exercised against missing-key, corrupt-JSON, and missing-file
inputs — all return 0 cleanly without aborting.

**Why it matters.** `gcp-management-tf/scripts/bootstrap.sh.tpl:543`
runs `jq -r '.azure_federated_apps | length'` against
`/etc/mgmt/federated-principals.json`. If the `azure_federated_apps`
key ever goes missing (manual edit, future-template refactor, partial
migration), `length` returns `null` and the `[[ "$AZ_LABEL_COUNT" -gt
0 ]]` arithmetic test at :553 errors out with bash's "integer
expression expected" — `set -e` aborts the entire bootstrap.
Equivalently, jq exec failure (corrupt JSON) propagates an error
through `$()` and aborts the same way. The new zero-app guard added
in P0 Item 4 is the right shape but is now the SOLE protection
against operator-triggered abort.

**Proposed fix.**

```bash
AZ_LABEL_COUNT="$(jq -r '(.azure_federated_apps | length) // 0' /etc/mgmt/federated-principals.json 2>/dev/null || echo 0)"
if [[ "${AZ_LABEL_COUNT:-0}" -gt 0 ]]; then
  ...
```

Same defensive pattern is appropriate at any other `jq | length`
arithmetic site in the bootstrap.

### 26. `id -gn` stderr swallowed by `2>/dev/null || true`

**Status:** Done. Took the simpler proposed path: dropped both
`2>/dev/null` and `|| true` from the assignment so `set -e` aborts with
`id -gn`'s native stderr surfaced. The `:?` re-guard before the
`<<SERVICE` heredoc is retained as defence-in-depth against the variable
being cleared between assignment and use. **Caveat (item 34 below):** an
edge case where `id -gn` succeeds but emits whitespace-only output is
not caught by `${VAR:?}` (which fires only on unset/empty). Pre-existing
risk profile, not introduced by this change.

**Why it matters.** `gcp-management-tf/scripts/bootstrap.sh.tpl:373`
(introduced as part of P0 Item 4 Item C `PERSONA_GROUP` guard)
captures `PERSONA_GROUP="$(id -gn "$VM_USER" 2>/dev/null || true)"`.
The `:?` guard at :380 fires correctly on empty value, but the
operator sees only the generic `persona group unresolved — ensure
phase 6 (user creation) ran before phase 8 (federation)` message.
If `id -gn` failed because of NSS misconfig, sssd timeout, or
`/etc/group` corruption, the actual diagnostic — which the previous
shape (no `|| true`) would have surfaced via `set -e` abort and the
`id` command's native stderr — is now hidden.

**Proposed fix.** Capture and re-emit:

```bash
PERSONA_GROUP_ERR="$(id -gn "$VM_USER" 2>&1 >/dev/null)" || true
PERSONA_GROUP="$(id -gn "$VM_USER" 2>/dev/null || true)"
: "${PERSONA_GROUP:?persona group unresolved (id -gn stderr: ${PERSONA_GROUP_ERR:-<empty>}) — ensure phase 6 ran before phase 8}"
```

Or simpler: drop the `|| true` from the assignment, let `set -e`
abort with `id`'s native stderr, and keep the `:?` guard only at the
pre-`<<SERVICE` heredoc site (its real job is defence-in-depth
against the variable being CLEARED between :373 and :447).

### 27. Azure `tenant_id`-null edge case in remote-state merge

**Status:** Done. `gcp-management-tf/main.tf` filter for
`azure_federated_apps_from_state` now requires both
`try(rs.outputs.mgmt_vm_app_client_id, null) != null` AND
`try(rs.outputs.mgmt_vm_tenant_id, null) != null`. Filter is currently a
tautology (the cluster stack's `mgmt_vm_tenant_id` is sourced from
`data.azurerm_client_config.current.tenant_id` which is always
populated), but the defence-in-depth is cheap and reads correctly to a
future maintainer.

**Why it matters.** `gcp-management-tf/main.tf:31-39` filters Azure
remote-state entries on `mgmt_vm_app_client_id != null` only. The
constructed map value also depends on `mgmt_vm_tenant_id`. Today
`mgmt_vm_tenant_id` is sourced from `data.azurerm_client_config.current`
which is always populated, so this is latent. But if the cluster
stack's azurerm provider was ever unauthenticated at apply time, or
the output renamed/refactored, an entry with `client_id != null` and
`tenant_id == null` could be merged in, producing
`AZURE_TENANT_ID=''` in the operator's profile.d while
`AZ_LABEL_COUNT > 0` (so the new zero-app guard doesn't fire).

**Proposed fix.** Tighten the filter to require both:

```hcl
azure_federated_apps_from_state = {
  for label, rs in data.terraform_remote_state.azure_aks :
  label => {
    client_id        = rs.outputs.mgmt_vm_app_client_id
    tenant_id        = rs.outputs.mgmt_vm_tenant_id
    subscription_ids = []
  }
  if try(rs.outputs.mgmt_vm_app_client_id, null) != null
  && try(rs.outputs.mgmt_vm_tenant_id, null) != null
}
```

Cheap defence; reads correctly to a future maintainer.

### 28. `azure-aks-tf/roadmap.md:68` checkbox semantics inconsistent

**Status:** Done. Line at `azure-aks-tf/roadmap.md:68` rewritten as
"Maintenance window decision — recorded as P2#13 non-goal..." per the
proposed text.

**Why it matters.** The line `- [x] Maintenance window — deliberately
omitted (P2#13 non-goal...)` (introduced by Item 22 sub-item 4)
checks the "done" box but the body says the feature was NOT built.
A reader scanning for completed work gets a misleading signal.

**Proposed fix.** Either uncheck (the feature wasn't built) or
rephrase so the checkbox reads as "decision documented":

```markdown
- [x] Maintenance window decision — recorded as P2#13 non-goal
      (clusters are routinely destroyed when idle, so a maintenance
      window adds operational burden without benefit).
```

### 29. AWS CMK teardown wording — KMS pending-deletion is mandatory

**Status:** Done. `bootstrap-state/aws/README.md` teardown section now
explicitly calls out the mandatory 7-30 day pending-deletion window and
the `--pending-window-in-days` configurability, replacing the
operator-discretion "cooling-off period" framing.

**Why it matters.** `bootstrap-state/aws/README.md` (added by P0 Item
5b hardening) recommends "schedule manual deletion via the console
after a cooling-off period." Reads as operator-discretion waiting;
in fact KMS enforces a 7-30 day pending-deletion window via
`schedule-key-deletion --pending-window-in-days N`. An operator
could interpret "cooling-off" as "wait a day before clicking delete"
and be surprised by KMS's mandatory minimum.

**Proposed fix.** One-line tightening: "...then schedule deletion via
the console — KMS enforces a mandatory 7-30 day pending-deletion
window (configurable via `--pending-window-in-days`) after which the
key is destroyed and any ciphertext encrypted with it is
unrecoverable."

### 30. Mirror `init -upgrade` lock-file note in sibling READMEs

**Status:** Done. The proposed pointer-link block was added to
`aws-eks-tf/README.md`, `azure-aks-tf/README.md`, and
`bootstrap-state/azure/README.md`, all linking to
`gcp-management-tf/README.md#bumping-provider-pins` (verified to match
the existing `### Bumping provider pins` heading at
gcp-management-tf/README.md:185). `bootstrap-state/azure/README.md`
uses `../../` since the stack is two levels deep; siblings use `../`.
Coverage scoped to READMEs that already discuss provider pins; the
three bootstrap-state READMEs without pin sections were not touched.

**Why it matters.** Item 21 documented the `init -upgrade` lock-file
gotcha in `gcp-management-tf/README.md` only, but the failure mode is
provider-agnostic — anyone bumping `aws ~> 5.x` in `aws-eks-tf` or
`azurerm ~> 4.x` in `azure-aks-tf` / `bootstrap-state/azure` hits the
identical issue. Operators reading the wrong stack's README won't
find the fix.

**Proposed fix.** Tactical: add a one-line pointer to each sibling
stack's README where provider pins are bumped:

```markdown
> Bumping a provider pin? See
> [`gcp-management-tf/README.md#bumping-provider-pins`](../gcp-management-tf/README.md#bumping-provider-pins)
> for the `init -upgrade` lock-file edge case.
```

Strategic alternative: move the subsection to `proj_roadmap.md` (or
a new `CONTRIBUTING.md`) and link to it from each per-stack README.
Tactical is the lower-friction fix and consistent with the lab's
existing "each stack's README is self-contained" pattern.

### 31. `prevent_destroy` on `nat-ip` conflicts with routine mgmt-stack teardown

**Status:** Done — Option (a). The escape-hatch comment block on
`google_compute_address.nat` in
`gcp-management-tf/modules/network/main.tf` now has an
"Operating-principle note" stanza explicitly acknowledging the two-step
teardown as the new normal for this stack. The trade (IP stability
across applies vs. one extra edit per teardown) is documented inline so
operators reading the resource find context without needing to consult
the roadmap. Options (b) scripted toggle and (c) conditional lifecycle
are NOT pursued.

**Why it matters.** Item P0#2.4 added `lifecycle { prevent_destroy =
true }` to `google_compute_address.nat` in
`gcp-management-tf/modules/network/main.tf:41-69` to keep the static NAT
IP stable across applies. But the lab's operating principle #2 says
"clusters routinely destroyed when idle" — and the same applies to the
mgmt stack (operators tear it down between sessions). With the guard in
place, plain `terraform destroy` on `gcp-management-tf` now hard-fails
until the lifecycle block is commented out. The current comment frames
this as a one-time migration ("two-step manoeuvre") rather than a
routine teardown step. Either:

- **Option (a) — accept the friction.** Update the comment to
  acknowledge the two-step destroy as the new normal for this stack,
  and document the trade (IP stability across applies vs. one-extra-edit
  per teardown). Consistent with the "load-bearing IP" framing.
- **Option (b) — scripted toggle.** Add a `Makefile` target or
  `scripts/teardown-mgmt.sh` that auto-comments the lifecycle, runs
  `terraform destroy`, and reverts. Faster but adds machinery.
- **Option (c) — make it conditional.** Wrap the lifecycle in a
  `dynamic "lifecycle"` block (not directly possible — `lifecycle` is
  meta) OR introduce a feature variable `protect_nat_ip` (default true)
  that gates whether the resource is created via separate
  `google_compute_address` resources. More refactor.

**Proposed fix.** Default to (a) — reword the comment to acknowledge
routine teardown as the expected workflow. Operator paste-dance for
`authorized_cidrs` is already a known cost; the lifecycle toggle is one
more line in the same workflow. Decide before the next mgmt-stack
teardown.

### 32. P0#4.7 apply-time preflight against `az account list` is missing

**Status:** Done. `preflight_main()` in
`gcp-management-tf/scripts/bootstrap.sh.tpl` now validates configured
`subscription_ids` against `az account list` per Azure label. New
sub-validation block reuses the same `az login --federated-token-file`
session that the existing TCP probes use; uses `configured_subs`
(populated once via jq) for both the new diff and the existing TCP-probe
loop (no duplicate jq query); emits a distinct `?? az account list
returned empty for label $label — possible AAD outage or transient
auth` line BEFORE per-sub diagnostics when the accessible set is empty,
so operators triage upstream auth before chasing typos. Per-sub `??
subscription <sub> configured for label <label> but not visible to the
SP — check assignment/typo` lines fire for each missing sub. New
`sub_warnings` counter threads through to a conditional summary suffix
emitted only when warnings > 0. The runtime `!! subscription not
accessible` diagnostic from Round 2 stays as the second line of
defence.

**Why it matters.** P0#4.7's runtime diagnostic for inaccessible
subscriptions landed (the `!! subscription $sub not accessible to $label`
message in `bootstrap.sh.tpl`'s Azure loop). The roadmap's proposed fix
also called for an apply-time preflight that validates every configured
`subscription_id` against `az account list` so typos are caught BEFORE
the operator runs `refresh-kubeconfigs`. The preflight half didn't land
— operators typo'ing a sub_id in `subscription_ids` still discover it
only at refresh-kubeconfigs time.

**Proposed fix.** Extend `preflight_main()` in
`gcp-management-tf/scripts/bootstrap.sh.tpl` to:

1. Iterate `azure_federated_apps[].subscription_ids[]` from
   `/etc/mgmt/federated-principals.json`.
2. Once per label, call `az account list --output tsv --query '[].id'`
   to enumerate subs the federated SP can see.
3. Diff configured against accessible; emit one distinct warning per
   missing sub: `"  ?? subscription $sub configured for label $label but
   not visible to the SP — check assignment/typo"`.

Low priority: the runtime diagnostic carries most of the value. File as
P1.

### 33. `create_before_destroy` on AAD chain — verify on first
       `cluster_name` rename

**Status:** Deferred to first real rename. The chain is correct in
theory and `terraform validate` is clean across all the CBD'd
resources, but empirical confirmation requires a real `cluster_name`
edit + `terraform plan` capture. This is an operational verification
task, not a code task — no implementation can close it. Filed here as
a permanent "verify next time the situation arises" note so future
maintainers know to capture the plan output and confirm the order
described in P0#1.6's status entry.

**Why it matters.** P0#1.6 propagated `lifecycle {
create_before_destroy = true }` through the AAD chain (App → SP →
FedCred → role assignment) so a `cluster_name` rename rotates the
identity without an auth-gap window. The chain is correct in theory;
empirical verification with a real `cluster_name` change is owed.

**Proposed fix.** When the next opportunity arises — a real rename, a
test stack, or a deliberate re-apply with a one-character `cluster_name`
edit — capture the resulting `terraform plan` output and confirm the
order is create-new-App → SP → FedCred → RA → destroy-old-RA → FedCred
→ SP → App. If the plan shows a destroy-then-create on any link, the
chain has a missed CBD edge or a non-CBD-compatible attribute. Strictly
informational; no code change unless the verification fails.

### 34. `PERSONA_GROUP` whitespace-only edge case

**Status:** Done. Hardening applied immediately after the
`PERSONA_GROUP="$(id -gn "$VM_USER")"` assignment in
`gcp-management-tf/scripts/bootstrap.sh.tpl` phase 8: a
`[[ -n "${PERSONA_GROUP// /}" ]] || { echo ...; exit 1; }` guard with a
5-line rationale comment. Note: `${VAR// /}` strips spaces only — see
item 39 below for the residual tab/newline edge.

**Why it matters.** Item 26 dropped the `2>/dev/null || true`
suppression on `PERSONA_GROUP="$(id -gn "$VM_USER")"` in
`gcp-management-tf/scripts/bootstrap.sh.tpl:373` so `set -e` aborts on
`id` failure. Correct for the primary failure mode. But there's a
residual edge: if `id -gn` succeeds but emits whitespace-only output
(NSS plugin returning a malformed entry, or `getent group` quirk), the
assignment succeeds, `set -e` does NOT fire, and the `:?` guard at the
heredoc fires only on unset/empty — not on whitespace.

**Proposed fix.** Either keep the current shape (good enough for any
realistic NSS configuration) or harden:

```bash
PERSONA_GROUP="$(id -gn "$VM_USER")"
[[ -n "${PERSONA_GROUP// /}" ]] || {
  echo "phase 8: id -gn returned whitespace-only result for $VM_USER" >&2
  exit 1
}
```

Strictly defensive; pre-existing risk profile, not introduced by Item
26.

### 35. `KUBECONFIG` ownership churn from per-context kubelogin in non-login shells

**Status:** Done. `refresh-kubeconfigs` block in
`gcp-management-tf/scripts/bootstrap.sh.tpl` now exports
`VM_USER` / `PERSONA_GROUP` / `KUBECONFIG` near the top (after the
`--preflight` case statement, before the GCP block). `mkdir -p`/`touch`
on `$HOME/.kube` paths replaced with explicit `/home/$VM_USER/.kube`
equivalents. Each cloud's block (GCP, AWS, Azure) is followed by a
`chown -R "$VM_USER:$PERSONA_GROUP" "/home/$VM_USER/.kube"` gated on
`[[ $EUID -eq 0 ]]` so the chown only runs when invoked via sudo (a
same-uid run already owns the files; chown to "self:self" against a
prior root-owned component would EPERM and abort the script under
`set -e`).

**Why it matters.** P0#4.6 added per-context `kubelogin
convert-kubeconfig --context "$ctx"` calls in the Azure loop of
`refresh-kubeconfigs`. Both `az aks get-credentials` and `kubelogin
convert-kubeconfig` write to `$KUBECONFIG` (defaults to
`$HOME/.kube/config`). When `refresh-kubeconfigs` is invoked from the
systemd timer, cron, or a non-login `sudo` shell, `$HOME` may resolve to
root's home rather than the persona user's, leading to file ownership
churn or split kubeconfigs. Pre-existing concern (the GCP/AWS blocks
have the same risk); P0#4.6 multiplies the surface area by N AKS
contexts.

**Proposed fix.** Either:

- Set `KUBECONFIG="/home/$VM_USER/.kube/config"` explicitly at the top
  of `refresh-kubeconfigs` and `chown -R "$VM_USER:$PERSONA_GROUP"
  "/home/$VM_USER/.kube"` after each cloud's block.
- Document that `refresh-kubeconfigs` is only safe to run interactively
  as the persona user (not from cron/systemd).

Default to (a) — the systemd timer for token refresh already runs as
the persona user via `User=`, so the same posture applies here.

### 36. `AZURE_CTXS` array is not de-duplicated

**Status:** Done. Two-line dedupe added before the convert-kubeconfig
loop in the Azure block of `refresh-kubeconfigs`:
`mapfile -t AZURE_CTXS < <(printf '%s\n' "${AZURE_CTXS[@]}" | sort -u)`
with a one-line comment explaining the rationale.

**Why it matters.** The new `AZURE_CTXS+=("$ctx")` accumulator in
`gcp-management-tf/scripts/bootstrap.sh.tpl` (P0#4.6) appends the
context name on every successful `az aks get-credentials`. If two AKS
clusters across two subscriptions share `(label, name)` (operator with
overlapping tenants, or duplicate-name across subs), `kubelogin
convert-kubeconfig --context "$ctx"` runs twice on the same context.
Idempotent (no harm), but slightly noisy.

**Proposed fix.** De-duplicate before the convert loop:

```bash
mapfile -t AZURE_CTXS < <(printf '%s\n' "${AZURE_CTXS[@]}" | sort -u)
```

Two-line fix; low priority.

### 37. P0#1.5 filter is currently a tautology

**Status:** Done. One-line tautology-explicit comment added immediately
above the `try(rs.outputs.mgmt_vm_tenant_id, null) != null` clause in
`gcp-management-tf/main.tf`'s `azure_federated_apps_from_state` block:
*"tenant_id-null check is presently a tautology (the cluster stack
sources tenant_id from data.azurerm_client_config.current which is
always populated) — kept as defence-in-depth against producer-side
refactors that could change the contract."*

**Why it matters.** Item P0#1.5 reworded `mgmt_vm_tenant_id`'s output
description but kept the output unconditional. Item 27 then tightened
the consumer-side filter in `gcp-management-tf/main.tf` to require both
`mgmt_vm_app_client_id != null` AND `mgmt_vm_tenant_id != null`. Today
the second clause is dead code — `data.azurerm_client_config.current.tenant_id`
is always populated. This is purely a noted observation: the
defence-in-depth is correct and cheap, but a future maintainer reading
the filter shouldn't conclude that `tenant_id == null` is a real path.

**Proposed fix.** Either:

- Keep the filter as-is and add a one-line comment noting the tautology
  is deliberate defence-in-depth.
- Tighten the producer side too: gate `mgmt_vm_tenant_id` output on the
  feature variable so it actually returns null when federation is off.
  More invasive; only worth it if a future change makes the consumer
  filter actually load-bearing.

Default to the comment-only fix. Strictly informational.

### 38. ARN regex `^arn:aws[a-z-]*:` accepts trailing/double-dash typos

**Status:** Done. Regex in `aws-eks-tf/variables.tf` `cluster_admin_principal_arns`
validation block tightened from `^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/`
to `^arn:(aws|aws-[a-z]+(-[a-z]+)*):iam::[0-9]{12}:(user|role)/`.
Verified via terraform console smoke test against 6 valid partition
forms (`aws`, `aws-cn`, `aws-us-gov`, `aws-iso`, `aws-iso-b`) and 6
malformations (`aws-`, `aws---cn`, `aws-cn-`, `aws-CN`, `arn::`, `awscn`)
— all valid forms accepted, all malformations rejected. error_message
updated to enumerate non-commercial partitions.

**Why it matters.** `aws-eks-tf/variables.tf` (the new regex from item
P0#3.2) accepts `arn:aws-:iam::...` and `arn:aws---cn:iam::...` because
the character class `[a-z-]*` permits any sequence of letters and
dashes, including empty / leading / consecutive dashes. Real AWS
partitions are limited to `aws`, `aws-cn`, `aws-us-gov`, `aws-iso`,
`aws-iso-b`. The malformed ARN would be rejected by the AWS API at
apply time, but the plan-time validation message says "Every entry
must be an IAM user or role ARN" — slightly misleading when the
malformation is in the partition prefix.

**Proposed fix.** Replace with a tighter regex:

```hcl
condition = alltrue([
  for arn in var.cluster_admin_principal_arns :
  can(regex("^arn:(aws|aws-[a-z]+(-[a-z]+)*):iam::[0-9]{12}:(user|role)/", arn))
])
```

Optional. The current regex is functionally correct for all real
ARNs; only synthetic typos slip through. Low priority.

### 39. `${PERSONA_GROUP// /}` whitespace check is space-only

**Status:** Done. `bootstrap.sh.tpl` PERSONA_GROUP guard switched from
`${PERSONA_GROUP// /}` (space-only) to `${PERSONA_GROUP//[[:space:]]/}`
(POSIX class — strips spaces, tabs, newlines, and other whitespace).
Mechanical one-character-class change; rendered output verified clean
via `bash -n`.

**Why it matters.** Item 34's whitespace guard in `bootstrap.sh.tpl`
uses `${VAR// /}` which strips spaces only — not tabs, newlines, or
other whitespace. POSIX group names disallow whitespace by spec, so
real-world impact is essentially zero, but a future NSS plugin that
emits malformed entries (tabs in group names) would slip past the
guard.

**Proposed fix.** Replace with the bash character-class form:

```bash
[[ -n "${PERSONA_GROUP//[[:space:]]/}" ]] || { ... }
```

Strictly defensive; one-character regex change. Low priority.

### 40. `.terraform.lock.hcl` consistency across `bootstrap-state/` siblings

**Status:** Lock files generated; commit decision deferred. `terraform
init -backend=false` run in `bootstrap-state/aws/` and `bootstrap-state/gcp/`
generated `.terraform.lock.hcl` files (pinning `hashicorp/aws 5.100.0`
and `hashicorp/google 6.50.0` respectively, both compatible with their
`versions.tf` constraints). Files left untracked in working tree pending
operator commit decision (this orchestration session does not commit
files). The remaining work is one `git add` to align with the existing
committed `bootstrap-state/azure/.terraform.lock.hcl`.

**Why it matters.** `bootstrap-state/azure/.terraform.lock.hcl` is
committed; `bootstrap-state/aws/` and `bootstrap-state/gcp/` don't
have lock files in source control. On first `terraform init` against
the AWS or GCP siblings, an untracked `.terraform.lock.hcl` is
generated, polluting `git status`. Lock-file consistency across
sibling stacks helps reproducibility (every operator gets the same
provider versions on first init).

**Proposed fix.** Either:
- Commit `.terraform.lock.hcl` for `bootstrap-state/aws/` and
  `bootstrap-state/gcp/` (matches the Azure sibling and the cluster
  stacks).
- Or add `.terraform.lock.hcl` to `.gitignore` and remove it from the
  Azure sibling (gives up reproducibility — anti-pattern, but consistent).

Default to the first option. Audit other stacks (`gcp-management-tf`,
`gcp-gke-tf`, `aws-eks-tf`, `azure-aks-tf`) for the same — they
already commit lock files per the cluster-stack convention. Cheap
follow-up; one `git add` per missing file.

### 41. `id -gn` failure in refresh-kubeconfigs has no script context

**Status:** Done. The `PERSONA_GROUP="$(id -gn "$VM_USER")"` site in
`refresh-kubeconfigs` (gcp-management-tf/scripts/bootstrap.sh.tpl
~lines 945-953) now wraps with two guards mirroring phase 8: an `||
{ echo ...; exit 1; }` for `id -gn` failure (NSS hiccup, stale
vm_username render) tagged `[refresh-kubeconfigs]` for script
context, and a `[[ -n "${PERSONA_GROUP//[[:space:]]/}" ]]` POSIX-class
whitespace check for malformed NSS output. Phase 8's existing guards
remain unchanged. Rendered template + `bash -n` clean.

**Why it matters.** Item 35 added an unconditional
`PERSONA_GROUP="$(id -gn "$VM_USER")"` near the top of
`refresh-kubeconfigs` in `gcp-management-tf/scripts/bootstrap.sh.tpl`.
If `id -gn` fails at refresh-kubeconfigs time (NSS hiccup, sssd
timeout, or a stale-rendered `vm_username` from a prior apply that no
longer exists), `set -euo pipefail` aborts the script with bare `id:
<user>: no such user` and no script context. The phase-8 site has the
same risk and addresses it with a custom diagnostic; the
refresh-kubeconfigs site does not.

**Proposed fix.** Wrap with a one-line diagnostic mirroring phase 8:

```bash
PERSONA_GROUP="$(id -gn "$VM_USER")" || {
  echo "[refresh-kubeconfigs] id -gn failed for $VM_USER — NSS issue or stale render of vm_username" >&2
  exit 1
}
```

Plus the same whitespace-class guard from Item 39:

```bash
[[ -n "${PERSONA_GROUP//[[:space:]]/}" ]] || {
  echo "[refresh-kubeconfigs] id -gn returned whitespace-only result for $VM_USER" >&2
  exit 1
}
```

Strictly defensive; pre-existing risk profile, surfaced by Item 35's
explicit-path refactor. Low priority.

### 42. GKE `node_config.labels = var.labels` leaks tag semantics into Kubernetes node labels

**Why it matters.** P2#11's sub-item fixed the analogous AKS leak
(`node_labels = merge(var.tags, ...)`). GKE has the same shape at
`gcp-gke-tf/gke.tf:163` — `google_container_node_pool.node_config.labels
= var.labels`. In the GCE provider, `node_config.labels` ARE Kubernetes
node labels (GCE instance labels are set elsewhere, on the underlying
MIG). `var.labels` is currently documented as "applied to all resources
that support them" — same dual-purpose tag-vs-Kubernetes-label
confusion that P2#11's sub-item just resolved on AKS. A label like
`environment=lab` ends up scheduler-visible on GKE nodes.

**Proposed fix.** Mirror P2#11's resolution: split the variable
contract or hardcode the literal map. Two options:

- **Option (a) — split.** Introduce `var.node_labels` (default `{}`)
  alongside `var.labels`; have `node_config.labels` consume the new
  variable. Resource-tagging consumers of `var.labels` keep their
  current shape.
- **Option (b) — literal map.** Replace `node_config.labels = var.labels`
  with `node_config.labels = { "lab.purpose" = "security-research" }`,
  matching the AKS shape. Simpler; loses operator-overridability of
  node labels (rarely needed for a lab).

Default to option (b) for symmetry with the AKS resolution.

**Operator note.** As with the AKS fix, existing GKE clusters applied
with the old shape will roll their node pool on the next apply to
drop tag-derived labels. Drain workloads before applying.

---

## P2 — Deferred / explicitly-not-doing

These appeared in earlier versions of the roadmap. Under the new
operating principles they are explicit *non-goals* or
low-priority.

### 11. Tag / label schema harmonization — NOT DOING

Each stack uses its cloud-native shape (`labels` on GCP, `tags`
with `default_tags` on AWS, per-resource `tags` on Azure). These
are not "wrong" — they are idiomatic. The real item from the prior
review that IS worth doing: **stop merging `var.tags` into AKS
`node_labels`** at `azure-aks-tf/aks.tf:152-157` and `:292-298`.
That leaks tag semantics into Kubernetes node labels where the
scheduler sees them.

```hcl
# azure-aks-tf/aks.tf — both node_labels blocks
node_labels = {
  "lab.purpose" = "security-research"
}
# (on the Spot pool, add "kubernetes.azure.com/scalesetpriority" = "spot")
```

No other tag-shape changes.

**Status (sub-item):** Done. Both `node_labels = merge(var.tags, ...)`
blocks in `azure-aks-tf/aks.tf` (default node pool ~line 152-159, Spot
pool ~line 273-281) replaced with literal map values. `tags = var.tags`
preserved on the resource and on both pools. `terraform validate`
clean.

**Operator note:** existing AKS clusters previously applied with the
merged shape will see their default and Spot node pools roll on the
next `terraform apply` to drop the tag-derived labels (`environment`,
`purpose`, `managed-by` — populated from `var.tags`'s defaults). Drain
workloads before applying.

**Out-of-scope follow-up surfaced during review:** GKE has the same
shape at `gcp-gke-tf/gke.tf:163` (`labels = var.labels` inside
`google_container_node_pool.node_config`) — `node_config.labels` ARE
Kubernetes node labels, not GCE instance labels. Tracked as new item
42 below.

### 12. Flow log / audit log default alignment — NOT DOING

Each stack picks a default that makes sense for its cloud's cost
model. Harmonization across three clouds with different billing
shapes produces a lowest-common-denominator outcome that is worse
than the current per-stack defaults.

What IS worth doing, lazily: add an `enable_flow_logs` variable
(bool, default false) to `azure-aks-tf` where it's currently
missing entirely. Flip on if investigating something.

### 13. Maintenance window alignment — NOT DOING

Clusters in this lab are routinely destroyed when idle. A
"maintenance window" implies a cluster that runs 24/7. Skip.

Keep the existing GKE + AKS windows (they're already there and
cost nothing). Don't add one to EKS.

### 14. Observability / monitoring default alignment — NOT DOING

Same reasoning as flow logs. Per-stack defaults are cost-tuned to
each cloud's free tier. If a specific investigation needs better
metrics, flip the stack's own `enable_*_metrics` variable.

### 15. Encryption-at-rest parity (customer-managed keys) — NOT DOING

EKS has a KMS CMK for Secrets envelope encryption because AWS made
it one-resource-cheap. Replicating on GCP (Cloud KMS +
`database_encryption`) and Azure (Key Vault + KMS integration) adds
a Key Vault / KMS key that complicates `terraform destroy`. For a
lab that routinely destroys, that friction isn't worth it.

Revisit only if the lab ever hosts workloads where etcd contents
are meaningfully sensitive beyond "compromised vulnerable pod
secrets."

### 16. Variable naming harmonization (`use_spot_vms` vs `use_spot_instances`) — NICE-TO-HAVE

The old roadmap proposed `use_spot_nodes` across all three stacks.
Fine idea but not load-bearing. Do it in the same PR as another
touch to the stack, not as a standalone task.

### 17. `gcp-gke-tf/roadmap.md` is missing

**Status:** Done. `gcp-gke-tf/roadmap.md` written (151 lines) matching
the format of EKS/AKS sibling roadmaps. Sections: header pointer to
`../proj_roadmap.md`, Deployment assumptions, Prerequisites, Tasks
(Phases 1-6 anchored to real variables/resources in `variables.tf`,
`gke.tf`, `network.tf`, `iam.tf`), Smoke checks, Future work
(regional-cluster opt-in, Binary Authorization, Config Connector,
PodSecurity Admission profile — the four named in P2#17, plus
sibling-analog State+CI and Access sections), Notes/decisions.

The three siblings each have one; GKE doesn't. Write a thin one
when next touching that stack — remote state pointer to project
roadmap, regional-cluster opt-in, Binary Authorization, Config
Connector, PodSecurity Admission profile. Match the format of
`gcp-management-tf/roadmap.md`.

---

## Notes / decisions

- **Siblings, not mirrors.** Restated at the top; restated here
  because earlier versions of this doc pushed hard on parity.
  Reversed.
- **Mgmt VM is the anchor.** All three cluster stacks are clients
  to `gcp-management-tf`. If a cluster stack decision breaks the
  mgmt VM's ability to kubectl in, that's a P0 bug even if the
  stack is "correct" in isolation.
- **Clusters are ephemeral.** Expect frequent destroy/apply cycles.
  Remote state, stable references from the mgmt VM, and idempotent
  apply are higher-value than in a typical "cluster lives for a
  year" repo.
- **1–2 users, 1–2 pods.** Anything designed for more is
  over-engineering for this lab. Autoscaling, HA NAT, multi-AZ
  control plane quorum, etc. — all anti-features.
- **No long-lived secrets.** WIF from the mgmt VM's GCP SA is the
  auth model. AWS access keys and Azure SP client secrets should
  not appear anywhere in this repo, including as optional fallbacks.
