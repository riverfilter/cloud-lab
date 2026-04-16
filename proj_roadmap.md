# cloud-lab — Project Roadmap

Living document. Cross-cutting roadmap for the four sibling stacks
(`gcp-management-tf`, `gcp-gke-tf`, `aws-eks-tf`, `azure-aks-tf`).
Per-stack roadmaps continue to track single-stack work; this file
tracks items that span two or more stacks or describe the lab as a
whole.

---

## Operating principles

These supersede any "harmonize everything" implications in older
versions of this document.

1. **The three clusters are siblings, not mirrors.** A shared threat
   model (private nodes, restricted control plane, vulnerable-pod
   ready) and a shared cost posture (minimal footprint, Spot where
   safe). Cloud-native idiom wins over forced parity — if AKS
   expresses a concept via `azurerm_monitor_diagnostic_setting` and
   EKS expresses it via `enabled_cluster_log_types`, that divergence
   stays. We do NOT chase identical variable names, matching flow-log
   defaults, or a canonical tag schema for its own sake.
2. **1–2 users, 1–2 pods per cluster, not all running at once.** The
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
if [[ -f "$CONFIG" ]] && command -v aws >/dev/null; then
  jq -r '.aws_role_arns | to_entries[] | "\(.key) \(.value)"' "$CONFIG" | \
  while read -r label role_arn; do
    echo "[refresh-kubeconfigs] AWS: $label ($role_arn)"
    # Fetch GCP SA ID token (the VM's attached SA signs this)
    id_token=$(curl -fsSL -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com")
    # Exchange for temporary AWS creds
    creds=$(aws sts assume-role-with-web-identity \
      --role-arn "$role_arn" \
      --role-session-name "mgmt-vm-$label" \
      --web-identity-token "$id_token" \
      --duration-seconds 3600 \
      --query 'Credentials' --output json)
    export AWS_ACCESS_KEY_ID=$(jq -r '.AccessKeyId' <<<"$creds")
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.SecretAccessKey' <<<"$creds")
    export AWS_SESSION_TOKEN=$(jq -r '.SessionToken' <<<"$creds")

    # Discover clusters in every region (or a configured subset)
    for region in us-east-1 us-west-2; do
      mapfile -t CLUSTERS < <(aws eks list-clusters --region "$region" --query 'clusters[]' --output text 2>/dev/null)
      for c in "${CLUSTERS[@]}"; do
        [[ -z "$c" ]] && continue
        aws eks update-kubeconfig --region "$region" --name "$c" \
          --alias "aws-$label-$c" >/dev/null || true
      done
    done
  done
fi

# --- Azure ---
if [[ -f "$CONFIG" ]] && command -v az >/dev/null; then
  jq -r '.azure_federated_apps | to_entries[] | "\(.key) \(.value.client_id) \(.value.tenant_id)"' "$CONFIG" | \
  while read -r label client_id tenant_id; do
    echo "[refresh-kubeconfigs] Azure: $label"
    id_token=$(curl -fsSL -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=api://AzureADTokenExchange")
    az login --service-principal \
      --username "$client_id" \
      --tenant "$tenant_id" \
      --federated-token "$id_token" \
      --allow-no-subscriptions >/dev/null

    mapfile -t ROWS < <(az aks list --query '[].{n:name,g:resourceGroup}' -o tsv)
    for row in "${ROWS[@]}"; do
      [[ -z "$row" ]] && continue
      name=$(awk '{print $1}' <<<"$row")
      rg=$(awk '{print $2}' <<<"$row")
      az aks get-credentials --name "$name" --resource-group "$rg" \
        --context "azure-$label-$name" --overwrite-existing >/dev/null || true
      # Convert to kubelogin format (local_account_disabled = true)
      kubelogin convert-kubeconfig -l azurecli >/dev/null || true
    done
    az logout >/dev/null 2>&1 || true
  done
fi

echo "[refresh-kubeconfigs] contexts:"
kubectl config get-contexts -o name
```

All three sections tolerate the mgmt VM being offline from a given
cloud — a cluster that isn't running doesn't block refreshes of the
clusters that are.

### 5. Remote state

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

### 8. Output naming drift across cluster stacks

**Why it matters.** The mgmt VM's `refresh-kubeconfigs` (item 4)
will read outputs from each cluster stack's remote state. Keeping
the shape consistent means one parser, not three. Today:

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
| `aws-eks-tf`        | `10.30.0.0/16` | /19 per AZ from the /16 |
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
