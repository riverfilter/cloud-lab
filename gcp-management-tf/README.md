# GCP Management VM

Terraform stack that provisions a Debian 12 jump box on GCE for operator use:
Terraform, kubectl, gcloud, Docker, Python, Helm, k9s, and friends. The VM's
service account holds read-only discovery rights across the org so
`refresh-kubeconfigs` can pull credentials for every GKE cluster the
operator can see, without copying any keys.

## Architecture

```
                 +--------------------------------------------------+
                 |                    host project                  |
                 |                                                  |
  operator --->  |  IAP TCP forwarding  -->  firewall (22/tcp)      |
  (gcloud ssh)   |        |                                         |
                 |        v                                         |
                 |    +-------------------+                         |
                 |    |  mgmt-vm          |  SA: mgmt-vm-sa         |
                 |    |  Debian 12        |   |                     |
                 |    |  e2-standard-4    |   +--> org-level IAM    |
                 |    |  100 GB balanced  |        - clusterViewer  |
                 |    |  shielded VM      |        - projectViewer  |
                 |    +---------+---------+        - tokenCreator   |
                 |              |                                   |
                 |          Cloud NAT (egress: apt, github, gcr)    |
                 +--------------------------------------------------+
```

Blast radius: the SA is read-only. It cannot modify any resource in the org.
Operators who need to mutate something impersonate a purpose-built SA from
inside the VM (`gcloud --impersonate-service-account=...`), which keeps audit
trails clean and avoids long-lived keys on disk.

## Prerequisites

Before `terraform apply`:

1. **Terraform >= 1.5** and **gcloud SDK** on whatever workstation / CI
   runner will execute `terraform apply`. This stack makes no assumptions
   about where it is applied from.
2. **Org-level privilege** on the target org. The apply binds IAM at the
   org node — the applying principal needs
   `roles/resourcemanager.organizationAdmin` or equivalent security-admin
   rights. If that is not available, set `iam_scope = "project"` in
   tfvars, which restricts discovery to the host project only.
3. **Host project** in the target org, with billing enabled. The stack
   enables the APIs it needs.
4. **Application Default Credentials** authenticated as a principal with
   the rights above:
   ```
   gcloud auth application-default login
   gcloud config set project <host_project>
   ```
5. **(Optional) GCS bucket** for remote state if you intend to uncomment
   `backend.tf`.
6. **Dotfiles repo URL** — edit `terraform.tfvars` and set `dotfiles_repo`.
   The placeholder `https://github.com/REPLACE-ME/dotfiles.git` is a no-op
   (bootstrap detects it and skips).

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # set org_id, project_id, dotfiles_repo

make init
make validate
make plan
make apply
```

SSH into the VM via IAP (no public IP required):

```bash
make ssh
```

Or directly:

```bash
gcloud compute ssh mgmt-vm \
  --project=<host_project> \
  --zone=us-central1-a \
  --tunnel-through-iap
```

Once inside, assume the persona user (dotfiles, kubeconfig):

```bash
sudo -iu devops
kubectl config get-contexts
```

## Refreshing kubeconfigs

First boot populates `~/.kube/config` automatically. To re-discover after
new clusters come online:

```bash
# on the VM, as the persona user:
/usr/local/bin/refresh-kubeconfigs

# or from your workstation:
make refresh
```

## Inspecting the bootstrap

```bash
sudo tail -f /var/log/mgmt-bootstrap.log
cat /var/lib/mgmt-bootstrap.done   # timestamp of last successful run
```

The bootstrap script is idempotent. To re-run:

```bash
sudo BOOTSTRAP_LOGGING= bash <(gcloud compute instances describe mgmt-vm \
  --project=<proj> --zone=<zone> \
  --format='value(metadata.items.startup-script)')
```

## File layout

```
.
├── README.md
├── Makefile
├── roadmap.md
├── backend.tf              # commented GCS backend
├── versions.tf             # provider pins
├── providers.tf
├── variables.tf            # all root inputs
├── terraform.tfvars.example
├── main.tf                 # wires submodules
├── outputs.tf
├── modules/
│   ├── iam/                # SA + org/project IAM bindings
│   ├── network/            # VPC, subnet, IAP firewall, Cloud NAT
│   └── mgmt-vm/            # the GCE instance
└── scripts/
    └── bootstrap.sh.tpl    # first-boot + re-runnable provisioning
```

## Security posture

- OS Login enforced; project-wide SSH keys blocked.
- Shielded VM on (secure boot, vTPM, integrity monitoring).
- No public IP by default; SSH only via IAP tunnel.
- Firewall locks `22/tcp` to the IAP CIDR (`35.235.240.0/20`) regardless
  of whether a public IP exists.
- Explicit deny-all ingress rule belt-and-braces against misconfigured
  default rules.
- Service account scope: `cloud-platform`, but the SA itself holds only
  read/discovery roles — the scope is wide so that impersonation works,
  not because this SA can write.
- VPC flow logs enabled with 50% sampling.

## Cost note

Defaults run roughly:

- e2-standard-4: ~$100/mo on-demand, less with sustained-use discount.
- 100 GB pd-balanced: ~$10/mo.
- Cloud NAT: ~$1/mo idle + egress.

If the VM is not used 24/7, stop it when idle (`gcloud compute instances stop`).
The boot disk persists, so restart is cheap.
