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
across Items 1-5 and the P0-checklist are now closed; 26 robustness
follow-ups remain open** — quality polish rather than functional gaps.
See per-item `### P0 Item N — follow-up from implementation review`
subsections for the remaining unchecked boxes.

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
- [ ] Accept a `mgmt_vm_sa_email` variable so the binding in (2)
      above does not require the operator to read a string out of a
      sibling stack's output every apply. **Not started.** Only
      needed if/when option (2) is chosen; option (1) shipped instead.

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
- [ ] **Robustness — IAM role name not unique across EKS stacks.**
      `aws-eks-tf/iam.tf:156` names the role `"${var.cluster_name}-mgmt-vm"`.
      If two EKS stacks in the same account share a `cluster_name`
      (unlikely but allowed), the second apply collides on the IAM
      role. IAM is account-global; consider suffixing with region or
      a short stack id, or at minimum documenting the global-uniqueness
      constraint on `var.cluster_name`.
- [ ] **Robustness — AAD App `display_name` not unique across
      subscriptions in same tenant.** `azure-aks-tf/iam.tf:75` uses
      `"${var.cluster_name}-mgmt-vm"`. AAD App display_name is not
      enforced unique but operators filter by it; two clusters with
      the same `cluster_name` in the same tenant produce two Apps
      with identical display_names and ambiguous CLI listings. Same
      mitigation as above (suffix with subscription/region) or
      document the constraint.
- [ ] **Robustness — `data.tls_certificate.gcp_oidc` re-resolved every
      plan when feature is enabled.** Count-gating it off is correct
      and avoids plan-time DNS/TLS calls when disabled, but when
      enabled every `terraform plan` does an outbound TLS handshake
      to `accounts.google.com`. In an air-gapped CI runner this fails
      plan, not apply. Consider pairing the dynamic lookup with an
      operator-overridable `var.gcp_oidc_thumbprint` (empty → use
      data source, non-empty → use value) so CI can be pinned.
- [ ] **Robustness — `mgmt_vm_tenant_id` output leaks tenant id when
      feature is disabled.** `azure-aks-tf/outputs.tf:73` returns
      `data.azurerm_client_config.current.tenant_id` unconditionally.
      Tenant id is not secret, but the output description says "the
      mgmt VM federates into" which is misleading when federation is
      off. Either gate the output on the feature (wrap in a
      conditional returning null) or rewrite the description to say
      "current apply principal's tenant, for reference" to match
      behaviour.
- [ ] **Robustness — no `create_before_destroy` on the AAD App.**
      `azure-aks-tf/iam.tf:72`. Destroy-then-recreate of the App
      (e.g. on a `cluster_name` rename) leaves a window where the
      federated credential and role assignment are both gone; the
      mgmt VM loses AKS access for the duration of the apply. Low
      priority for a lab, but worth a `lifecycle { create_before_destroy = true }`
      once the pattern stabilises.
- [ ] **Robustness — no explicit depends_on from
      `aws_eks_access_policy_association.mgmt_vm` to
      `aws_iam_role.mgmt_vm_federated`.** The access-entry→
      access-policy-association `depends_on` is present
      (`aws-eks-tf/iam.tf:222`) but the access-entry itself only
      implicitly depends on the role via `principal_arn`. On a
      destroy cycle where the role is recreated (name change,
      force-replace), the access entry may try to reference an ARN
      that is mid-replacement. Add `depends_on = [aws_iam_role.mgmt_vm_federated]`
      to the access entry for belt-and-braces ordering.
- [ ] **Robustness — `cluster_admin_principal_arn` coexistence path
      not tested.** The landed item-1 change adds a parallel
      `aws_eks_access_entry.mgmt_vm` resource; item 3 of this roadmap
      consolidates admin principals into a list. Until item 3 lands,
      applying item 1 on a cluster that already has an operator
      access entry is fine, but the upgrade path (list-consolidation)
      has to preserve both entries without churn. Add a `moved`
      block plan when item 3 is authored, or verify via import
      that the transition is no-op.

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
- [ ] **Robustness — global name collision on
      `${var.name_prefix}-nat-ip`.**
      `gcp-management-tf/modules/network/main.tf:43`.
      `google_compute_address` names are unique per project+region.
      Two parallel mgmt-stack applies in the same project/region with
      the same `name_prefix` (different workspaces, or a
      dev/shared pair) collide at create time with a non-idempotent
      error. Fix: either add a validation warning on `name_prefix`
      uniqueness, or suffix with `random_id`/workspace name.
- [ ] **Robustness — no `lifecycle { prevent_destroy }` on
      `google_compute_address.nat`.**
      `gcp-management-tf/modules/network/main.tf:42-47`. The whole
      point of this change is IP stability; a stray `terraform
      destroy -target` or a refactor that moves the resource wipes
      the reservation and the next apply issues a fresh IP,
      silently breaking every cluster's `authorized_cidrs`. For a
      lab this is acceptable given the tear-down cadence, but a
      `prevent_destroy = true` (or at least a comment calling out
      the destroy footgun) matches the "load-bearing" framing in
      the adjacent comment.
- [ ] **Robustness — reserved IP bills when detached.** Reserved
      static external IPs are free only while in use. If the NAT is
      destroyed but the address survives (e.g. destroy ordering
      edge-case, partial apply failure, or `terraform state rm` on
      the NAT), the address quietly accrues ~\$0.005/hr. Low cost in
      absolute terms but worth a one-line comment near the
      `google_compute_address` resource noting the idle-bill
      behaviour so operators cleaning up a failed apply know to
      check.
- [ ] **Robustness — EKS/AKS tfvars hint should steer to one
      canonical variable name.** `aws-eks-tf/terraform.tfvars.example:8`
      and `azure-aks-tf/terraform.tfvars.example:12` both use
      `authorized_cidrs` (list of strings). The root
      `nat_public_ip` output description correctly implies a single
      variable name across all three stacks, and verification
      against `variables.tf` confirms the name matches in all three
      — good. But AKS's underlying azurerm field is
      `api_server_authorized_ip_ranges`; if the AKS stack is ever
      renamed to mirror the azurerm field, the cross-stack
      instruction in the mgmt output description will drift. Add a
      code comment or README cross-reference binding the three
      stacks' variable name to the output description.

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
- [ ] **Robustness — silent-failure mode when operator uses the
      two-apply dance without the mgmt VM ARN.** `aws-eks-tf/README.md:47-49`
      offers two valid ways to add the mgmt VM role ARN to the list:
      (a) pre-compute `arn:aws:iam::<account>:role/<cluster_name>-mgmt-vm`
      before first apply, or (b) read the `mgmt_vm_role_arn` output
      after apply and add it on a follow-up apply. Path (b) leaves
      the mgmt VM with valid AWS federated creds and
      `eks:DescribeCluster` (so `aws eks update-kubeconfig`
      succeeds) but *no* cluster-admin — `kubectl` returns
      `forbidden` until the second apply lands. If the operator
      forgets the second apply, Item 1's entire federated-identity
      stack ships functionally broken for EKS with no error
      surface. Fix: in `aws-eks-tf/README.md:47`, promote path (a)
      (pre-compute) as the default and demote (b) to "only if you
      must run the apply before you know the account ID",
      explicitly calling out the forbidden-kubectl interim state.
- [ ] **Robustness — ARN validation regex rejects non-commercial
      AWS partitions.** `aws-eks-tf/variables.tf:85` pins the
      prefix literal `^arn:aws:iam::`. China (`arn:aws-cn:`) and
      GovCloud (`arn:aws-us-gov:`) ARNs fail validation even though
      EKS access entries work identically there. Out of scope for
      the lab today, but the regex is trivially future-proofable
      and the error message would mislead any operator hitting it
      ("Every entry must be an IAM user or role ARN" — but it *is*
      one). Fix: change to `^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/`
      or document the commercial-partition-only constraint in the
      variable description.
- [ ] **Robustness — `toset()` silently dedupes duplicate ARNs.**
      `aws-eks-tf/eks.tf:110,118` convert the input list via
      `toset(var.cluster_admin_principal_arns)`. If an operator
      accidentally lists the same ARN twice (cut-and-paste), the
      second entry is collapsed with no warning. Harmless
      correctness-wise but masks a tfvars typo. Optional fix: add a
      `validation` block that asserts
      `length(var.cluster_admin_principal_arns) == length(toset(var.cluster_admin_principal_arns))`
      with a "duplicate ARN" error message. Skip if considered too
      nitpicky for a lab.
- [ ] **Robustness — `moved` block omission is defensible but the
      README's rationale overstates the constraint.**
      `aws-eks-tf/README.md:76` claims "the new address keys are
      ARNs that are only known at apply time (not expressable in
      source)". Verified against Terraform 1.14: `moved` blocks
      require *constant* keys and reject variable-referenced
      indexes — the implementer is correct that a generic
      source-committed `moved` block is impossible. BUT a per-operator
      literal `moved { from = aws_eks_access_entry.admin[0]; to = aws_eks_access_entry.admin["arn:aws:iam::<acct>:user/<you>"] }`
      dropped into a local `migrations.tf` before the first
      post-upgrade apply would work and leave plan output cleaner
      than `terraform state mv`. Fix: in the README upgrade
      section, offer the per-operator `moved` block as an
      alternative pattern for operators who prefer HCL-driven
      migrations, noting it requires a local-only file and is
      removable after the next apply. Strictly informational —
      current guidance is not wrong.

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
- [ ] **Robustness — `kubelogin convert-kubeconfig -l workloadidentity`
      runs once at the end of the Azure block with no
      `--context`/`--kubeconfig-filter` scope.**
      `gcp-management-tf/scripts/bootstrap.sh.tpl:759`. kubelogin walks
      every context and rewrites only the ones whose exec block names
      `kubelogin get-token` — so non-AKS contexts (GKE's
      `gke-gcloud-auth-plugin`, EKS's `aws eks get-token`) survive
      untouched today. But the conversion is unconditional: if a future
      GKE auth-plugin release starts shelling out to a helper that
      happens to match kubelogin's detection heuristic, or if an
      operator imports an AAD-enabled non-AKS cluster context, the
      rewrite silently clobbers auth. Fix: scope the call with
      `--context "azure-*"` (not supported) OR iterate the azure
      contexts just merged and call `kubelogin convert-kubeconfig
      --context <ctx>` per-context. Low probability, but defence in
      depth matches the "block is tolerant of the others" header
      comment.
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
- [ ] **Robustness — `az account set --subscription` for a sub the
      federated SP cannot see fails hard and the whole label's
      remaining subs are skipped.**
      `gcp-management-tf/scripts/bootstrap.sh.tpl:733-735`. The
      `|| { echo ...; continue; }` only continues the `for sub` loop
      — good — but an operator who typo'd a sub ID in
      `subscription_ids` gets one error line and silently-empty AKS
      discovery for that label. Fix: surface the sub-set failure
      distinctly from "no AKS clusters in this sub" (e.g. `echo
      "  !! subscription $sub not accessible to $label"`), and
      consider a preflight that validates every configured
      subscription_id against `az account list` at apply time.
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
- [ ] **Robustness — `.gitignore` pattern for `backend.hcl` is
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
