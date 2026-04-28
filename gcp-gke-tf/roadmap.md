# GCP GKE Lab — Roadmap

Living document. Tasks will be checked off as implementation lands.

Cross-stack context (mgmt VM as anchor, sibling cluster stacks, no
long-lived secrets, etc.) lives in `../proj_roadmap.md`. This file is
the per-stack delta only.

## Deployment assumptions

- This stack will **not** be applied from the author's local workstation
  without review, and **not** against a shared production project. All
  project identity is supplied by the operator at apply-time via
  `terraform.tfvars`.
- No local `gcloud` config, project, or principal from the authoring
  machine has been baked into defaults. `project_id` and
  `authorized_cidrs` are operator-supplied with placeholder examples
  in the example tfvars. The mgmt VM's NAT egress IP is the canonical
  second `authorized_cidrs` entry alongside the operator's own
  workstation /32.
- The applying principal authenticates wherever the apply actually runs
  (CI runner, mgmt VM, workstation) via ADC — the stack does not care
  how.

## Prerequisites the operator must provide before `apply`

- [ ] **`project_id`** — target GCP project (billing linked, APIs
      enabled per `README.md`).
- [ ] **`authorized_cidrs`** — list of `{cidr_block, display_name}`
      objects. At least one /32, no 0.0.0.0/0 (validation rejects it).
      The mgmt VM's NAT public IP (from `gcp-management-tf` output
      `nat_public_ip`) should be appended as a second entry so kubectl
      from the mgmt VM works.
- [ ] Project-level IAM sufficient to create VPC / GKE / Service
      Account / IAM-binding resources. A personal lab project with
      Owner is fine; tighten before reuse.
- [ ] Required APIs enabled: `compute`, `container`, `iam`,
      `iamcredentials`, `artifactregistry`. README has the
      `gcloud services enable` command.
- [ ] (Optional) GCS bucket for remote state if the commented
      `backend.tf` is adopted. See `bootstrap-state/gcp` for the
      bucket-provisioning stack.

## Tasks

### Phase 1 — Scaffolding
- [x] `versions.tf` — pin providers (google, google-beta)
- [x] `backend.tf` — commented GCS backend block
- [x] `variables.tf` — all inputs (project_id, region, zone,
      cluster_name, node_machine_type, node_count, use_spot_vms,
      authorized_cidrs, subnet/pods/services CIDRs,
      master_ipv4_cidr_block, labels)
- [x] `terraform.tfvars.example`
- [x] `providers.tf`
- [x] `outputs.tf`

### Phase 2 — Networking
- [x] Dedicated VPC + node subnet with secondary ranges for pods/services
- [x] Cloud Router + Cloud NAT (egress only)
- [x] Private nodes (no public IPs) with public, CIDR-restricted
      control plane endpoint

### Phase 3 — IAM
- [x] Dedicated least-privilege node service account
- [x] Workload Identity pool wired to `<project>.svc.id.goog`

### Phase 4 — GKE
- [x] Zonal private cluster, REGULAR release channel
- [x] Dataplane V2 (eBPF + NetworkPolicy enforcement)
- [x] `master_authorized_networks_config` from `authorized_cidrs`
- [x] Shielded Nodes, COS_CONTAINERD, legacy metadata disabled
- [x] One node pool, Spot by default, fixed size (no autoscaler)
- [x] Cost allocation enabled

### Phase 5 — Docs
- [x] `README.md` — prerequisites, deploy, mgmt-VM RBAC step, cost,
      agent-sizing note, vulnerable-workload warning
- [x] Update root `../README.md` stacks table

### Phase 6 — Verification
- [x] Manual HCL review for syntax issues
- [ ] `terraform fmt -recursive` — **operator to run on first use**
- [ ] `terraform init` + `terraform validate` — **operator to run**
- [ ] `terraform plan` with real tfvars — **operator to run**
- [ ] Confirm `gcloud container clusters get-credentials` populates
      `~/.kube/config` — **operator to run**
- [ ] Confirm `kubectl get nodes` returns Ready nodes — **operator to run**
- [ ] Confirm the post-apply `kubectl create clusterrolebinding
      mgmt-vm-admin ...` step from `README.md` — **operator to run**

## Future work

### Regional control plane opt-in
- [ ] Variable-gated regional cluster (`location = var.region`
      instead of `var.zone`) for the rare lab session that needs
      control-plane HA. Default stays zonal — ~$0.10/hr vs ~$0.30/hr
      is a non-trivial fraction of the lab's monthly burn.

### Binary Authorization
- [ ] `binary_authorization { evaluation_mode = ... }` on the
      cluster + a default policy that admits only signed images from
      a designated Artifact Registry. Useful once the lab grows past
      a single throwaway image set; today it would just block every
      `kubectl apply` of an upstream chart.

### Config Connector
- [ ] `gke-addon` (`config_connector_config { enabled = true }`) so
      GCP resources can be reconciled from in-cluster CRs. Adds an
      operator namespace and IAM binding for the connector SA;
      pencilled in as a future demo of "manage GCP from Kubernetes."

### PodSecurity Admission profile
- [ ] Namespace-level PodSecurity Admission labels
      (`pod-security.kubernetes.io/enforce=baseline` or `restricted`
      on namespaces hosting vulnerable workloads). Today nothing
      enforces a baseline at admission; vulnerable pods can request
      privileged/hostNetwork freely. Pair with the existing
      Dataplane V2 NetworkPolicy enforcement.

### State + CI
- [ ] Remote state: provision via `bootstrap-state/gcp`, uncomment
      `backend.tf`, migrate with
      `terraform init -backend-config=backend.hcl -migrate-state`.
- [ ] CI apply path via GitHub Actions + Workload Identity Federation
      to GCP (no long-lived service account keys).

### Access
- [ ] In-cluster `ClusterRoleBinding` for the mgmt VM SA via the
      `kubernetes` provider, replacing the manual post-apply
      `kubectl create clusterrolebinding mgmt-vm-admin` step in
      `README.md`. Adds a provider that has to reach the cluster API
      server from wherever `terraform apply` runs — tracked in
      `../proj_roadmap.md`.
- [ ] Read-only RoleBinding for an observer principal once the lab
      grows beyond admin-plus-nothing.

## Notes / decisions

- **Zonal control plane** is the default. Regional adds ~$0.20/hr
  for HA the lab does not need; clusters are routinely destroyed
  when idle.
- **Dataplane V2 + NetworkPolicy enforced.** Cheap defense-in-depth
  for a lab with intentionally vulnerable workloads.
- **Spot node pool by default.** ~60–91% cheaper; preemption is
  acceptable for lab work. Flip `use_spot_vms = false` if a workload
  can't tolerate it.
- **Mgmt-VM RBAC is a manual post-apply step.** GKE IAM grants
  authentication; in-cluster RBAC is a separate axis. See `README.md`.
- **Identity is supplied, not assumed.** Nothing in this stack
  encodes the author's project, region, or gcloud identity.
