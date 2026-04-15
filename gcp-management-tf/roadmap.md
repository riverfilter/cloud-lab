# GCP Management VM — Roadmap

Living document. Tasks will be checked off as implementation lands.

## Deployment assumptions

- This stack will **not** be applied from the author's local workstation, and
  **not** against the author's personal GCP org. All org/project identity is
  supplied by the operator at apply-time via `terraform.tfvars`.
- No local `gcloud` state, auth principal, or project from the authoring
  machine has been baked into defaults. `org_id` and `project_id` are
  required inputs with `REPLACE_ME_*` placeholders in the example tfvars.
- The applying principal authenticates wherever the apply actually runs
  (CI runner, bastion, etc.) via ADC — the stack does not care how.

## Prerequisites the operator must provide before `apply`

- [ ] Numeric **`org_id`** of the target GCP org.
- [ ] **Host project** in that org to hold the VM, SA, disk, and network.
- [ ] Applying principal has `roles/resourcemanager.organizationAdmin`
      (or the narrower pairing of `organizationIamAdmin` +
      `securityAdmin`) on the target org — required to bind IAM at the
      org node. Fall back to `iam_scope = "project"` if this is not
      available; GKE discovery will then be limited to the host project.
- [ ] Required APIs: the stack enables `compute`, `iam`, `iap`,
      `cloudresourcemanager`, `container`, `serviceusage` on the host
      project. Billing must be linked.
- [ ] A dotfiles repo URL (public, or reachable from the VM's egress
      path). The default placeholder is a no-op that the bootstrap
      detects and skips.
- [ ] (Optional) GCS bucket for remote state if the commented
      `backend.tf` is adopted.

## Tasks

### Phase 1 — Scaffolding
- [x] Write `roadmap.md` (this file)
- [x] `versions.tf` — pin providers
- [x] `backend.tf` — commented GCS backend block
- [x] `variables.tf` — all inputs (org_id, project_id, region, zone, machine_type, disk_size_gb, username, dotfiles_repo, allow_public_ip, enable_confidential, etc.)
- [x] `terraform.tfvars.example` — documented sample with REPLACE_ME placeholders (no personal org defaults)
- [x] `providers.tf`
- [x] `main.tf` — wires submodules
- [x] `outputs.tf`

### Phase 2 — IAM submodule
- [x] `modules/iam/` — create SA, bind org-level roles (clusterViewer, projectViewer, SA token creator, optional computeViewer)
- [x] Enable required APIs on the host project

### Phase 3 — Networking
- [x] VPC + subnet (or reuse default via variable)
- [x] Firewall: IAP SSH ingress (35.235.240.0/20 → :22)
- [x] Cloud NAT so the VM (no public IP) can reach APT/GitHub/gcr

### Phase 4 — VM module
- [x] `modules/mgmt-vm/` — `google_compute_instance`
  - Debian 12, e2-standard-4, 100 GB pd-balanced
  - Shielded VM on; confidential toggle
  - OS Login enabled via metadata
  - IAP-only by default; optional external IP
  - Startup script loaded from bootstrap file

### Phase 5 — Bootstrap script
- [x] `scripts/bootstrap.sh` — idempotent, phased, logs to `/var/log/mgmt-bootstrap.log`
- [x] APT repo setup: HashiCorp, Docker, Google Cloud SDK, Helm, GitHub CLI, Kubernetes
- [x] Package install
- [x] Create persona user (parameterized, default `devops`), add to `docker`, `sudo`
- [x] Dotfiles clone + idempotent install (install.sh preferred, stow fallback)
- [x] Install `/usr/local/bin/refresh-kubeconfigs` and run once on first boot
- [x] k9s, yq, terragrunt, sops, age via direct binary where no stable apt repo

### Phase 6 — Docs
- [x] `README.md` — prerequisites, deploy commands, ops notes
- [x] `Makefile` — init / fmt / validate / plan / apply / destroy / ssh

### Phase 7 — Verification
- [x] `terraform fmt -recursive` clean
- [x] `terraform init` succeeds
- [x] `terraform validate` succeeds (no tfvars supplied)
- [x] `templatefile(...)` render of `bootstrap.sh.tpl` parses with no interpolation/escaping errors
- [x] Scrub local-machine identity leakage from defaults and docs (org_id, project_id, auth principal, owner label)
- [ ] `terraform plan` with real tfvars — **operator to run, in the target environment**
- [ ] SSH via IAP after apply — **operator to run**
- [ ] Confirm `refresh-kubeconfigs` populates `~/.kube/config` — **operator to run**

## Notes / decisions

- **Org-level IAM bindings** are used deliberately so `gcloud container clusters list` finds clusters across every project in the org. Calling this out loudly because it requires elevated privileges at apply-time that project-scoped applies do not.
- **No public IP by default.** IAP tunnel is the supported access path. `allow_public_ip = true` flips to an ephemeral external IP + the same IAP firewall rule (still locked to IAP CIDR).
- **e2-standard-4 / 100 GB pd-balanced** chosen as a sweet spot: Terraform/kubectl/occasional docker builds are bursty but not sustained; e2 gets you 4 vCPU / 16 GB at roughly half the cost of n2 for this workload. 100 GB balanced gives headroom for docker layer cache + a couple of GKE node image pulls without paying for SSD IOPS the workload won't use.
- **Startup script**, not `cloud-init user-data`, because the Debian 12 GCE image ships with the Google startup-script agent wired up and it is the path of least surprise on GCE. Script is written to be safely re-runnable.
- **Identity is supplied, not assumed.** Nothing in this repo encodes the author's org, project, or gcloud identity. Defaults for required identity inputs are `REPLACE_ME_*` placeholders so an accidental `terraform apply` with no tfvars fails fast.
