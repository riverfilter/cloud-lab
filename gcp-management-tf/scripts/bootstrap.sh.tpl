#!/usr/bin/env bash
#
# Management VM bootstrap.
#
# Idempotent — safe to run on first boot and again as `sudo bash /etc/mgmt/bootstrap.sh`.
# Phases:
#   1. guardrails  (early exit if already green)
#   2. system      (apt update + base packages)
#   3. apt-repos   (HashiCorp, Docker, Google Cloud SDK, Helm, GitHub CLI, Kubernetes, Azure CLI)
#   4. packages    (tooling install — gcloud, kubectl, helm, terraform, azure-cli)
#   5. binaries    (tools without clean apt: terragrunt, k9s, yq, sops, AWS CLI v2, kubelogin)
#   6. user        (create ${vm_username}, groups, shell)
#   7. dotfiles    (clone + install.sh or stow)
#   8. federation  (render /etc/mgmt/federated-principals.json + systemd id-token timer + ~/.aws/config + /etc/profile.d/mgmt-azure-federated.sh)
#   9. kubeconfig  (refresh-kubeconfigs script + first-run across GCP/AWS/Azure)
#  10. done        (touch sentinel, log completion)
#
# All output tee'd to /var/log/mgmt-bootstrap.log.

set -euo pipefail

VM_USER="${vm_username}"
DOTFILES_REPO="${dotfiles_repo}"
DOTFILES_BRANCH="${dotfiles_branch}"

LOG=/var/log/mgmt-bootstrap.log
SENTINEL=/var/lib/mgmt-bootstrap.done
STATE_DIR=/var/lib/mgmt-bootstrap
mkdir -p "$STATE_DIR"

# Re-exec with all output captured.
if [[ -z "$${BOOTSTRAP_LOGGING:-}" ]]; then
  export BOOTSTRAP_LOGGING=1
  exec > >(tee -a "$LOG") 2>&1
fi

log() { echo "[$(date -Is)] $*"; }
phase() { log "===== PHASE: $* ====="; }

export DEBIAN_FRONTEND=noninteractive

########################################
# 1. guardrails
########################################
phase "1/10 guardrails"
if [[ $EUID -ne 0 ]]; then
  log "must run as root"; exit 1
fi

# Wait for cloud-init / package manager to settle — avoid racing the
# Google guest agent on first boot.
for i in {1..30}; do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
     ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  log "waiting for apt/dpkg lock... ($i)"
  sleep 5
done

########################################
# 2. system
########################################
phase "2/10 system update + base"
apt-get update -y
apt-get -y upgrade
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common

########################################
# 3. apt-repos
########################################
phase "3/10 apt repositories"

install -d -m 0755 /etc/apt/keyrings

# --- HashiCorp (terraform) ---
if [[ ! -f /etc/apt/keyrings/hashicorp-archive-keyring.gpg ]]; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list

# --- Docker ---
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

# --- Google Cloud SDK ---
if [[ ! -f /etc/apt/keyrings/cloud.google.gpg ]]; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list

# --- Kubernetes (kubectl) ---
# The pkgs.k8s.io repos are versioned; pin a stable minor.
K8S_MINOR="v1.31"
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/$${K8S_MINOR}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

# --- Helm ---
if [[ ! -f /etc/apt/keyrings/helm.gpg ]]; then
  curl -fsSL https://baltocdn.com/helm/signing.asc | \
    gpg --dearmor -o /etc/apt/keyrings/helm.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
  > /etc/apt/sources.list.d/helm-stable-debian.list

# --- GitHub CLI ---
if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# --- Microsoft (Azure CLI) ---
# Microsoft only ships amd64 Debian packages at packages.microsoft.com;
# skip the repo on arm64 and fall back to pip-installed azure-cli in
# phase 4. The keyring write is idempotent — reruns of the bootstrap
# replace the file only if missing.
if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
fi
if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/azure-cli.list
else
  rm -f /etc/apt/sources.list.d/azure-cli.list
fi

apt-get update -y

########################################
# 4. packages
########################################
phase "4/10 package install"
apt-get install -y \
  build-essential \
  git \
  htop \
  jq \
  tmux \
  unzip \
  vim \
  wget \
  zsh \
  fzf \
  ripgrep \
  bat \
  fd-find \
  stow \
  age \
  python3 \
  python3-pip \
  python3-venv \
  pipx \
  terraform \
  google-cloud-cli \
  google-cloud-cli-gke-gcloud-auth-plugin \
  kubectl \
  helm \
  gh \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Azure CLI ships amd64 debs via packages.microsoft.com; on arm64 the
# Microsoft repo is not populated, so fall back to pipx (isolated venv —
# pip-installing azure-cli system-wide collides with Debian's PEP 668
# externally-managed-environment lock).
if ! command -v az >/dev/null; then
  if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
    apt-get install -y azure-cli
  else
    log "azure-cli apt repo is amd64-only; installing via pipx"
    pipx install --global azure-cli || pipx install azure-cli
  fi
fi

systemctl enable --now docker

########################################
# 5. binaries (no clean apt)
########################################
phase "5/10 supplemental binaries"

ARCH="$(dpkg --print-architecture)"   # amd64 | arm64

# --- terragrunt ---
TG_VERSION="v0.66.9"
if ! command -v terragrunt >/dev/null || [[ "$(terragrunt --version 2>/dev/null | awk '{print $3}')" != "$TG_VERSION" ]]; then
  curl -fsSL -o /usr/local/bin/terragrunt \
    "https://github.com/gruntwork-io/terragrunt/releases/download/$${TG_VERSION}/terragrunt_linux_$${ARCH}"
  chmod +x /usr/local/bin/terragrunt
fi

# --- k9s ---
K9S_VERSION="v0.32.5"
if ! command -v k9s >/dev/null || [[ "$(k9s version -s 2>/dev/null | awk '/Version/{print $2}')" != "$K9S_VERSION" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/k9s.tgz" \
    "https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/k9s_Linux_$${ARCH}.tar.gz"
  tar -xzf "$tmp/k9s.tgz" -C "$tmp"
  install -m 0755 "$tmp/k9s" /usr/local/bin/k9s
  rm -rf "$tmp"
fi

# --- yq ---
YQ_VERSION="v4.44.3"
if ! command -v yq >/dev/null || [[ "$(yq --version 2>/dev/null | awk '{print $NF}')" != "$YQ_VERSION" ]]; then
  curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/$${YQ_VERSION}/yq_linux_$${ARCH}"
  chmod +x /usr/local/bin/yq
fi

# --- sops ---
SOPS_VERSION="v3.9.1"
if ! command -v sops >/dev/null || [[ "$(sops --version 2>/dev/null | awk '/^sops/{print $2}')" != "$${SOPS_VERSION#v}" ]]; then
  curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/$${SOPS_VERSION}/sops-$${SOPS_VERSION}.linux.$${ARCH}"
  chmod +x /usr/local/bin/sops
fi

# --- AWS CLI v2 ---
# Not in Debian repos. The official zip installer is the supported path
# and uses `uname -m` naming (`x86_64` / `aarch64`) rather than the
# dpkg `amd64` / `arm64` we use elsewhere in this script.
if ! command -v aws >/dev/null; then
  tmp="$(mktemp -d)"
  UNAME_M="$(uname -m)"
  curl -fsSL -o "$tmp/awscli.zip" \
    "https://awscli.amazonaws.com/awscli-exe-linux-$${UNAME_M}.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --update
  rm -rf "$tmp"
fi

# --- kubelogin (Azure workload-identity exec credential plugin) ---
# Required for AKS AAD auth with local_account_disabled=true. We use the
# workload-identity mode at kubectl time (see P0-sessions wiring in
# phase 8); that mode reads env vars set by /etc/profile.d and exchanges
# the federated token directly, so kubelogin never calls `az`.
# Release names follow kubelogin's convention: zip contains
# bin/linux_<arch>/kubelogin where <arch> is `amd64` or `arm64`.
KUBELOGIN_VERSION="v0.1.4"
if ! command -v kubelogin >/dev/null || \
   [[ "$(kubelogin --version 2>/dev/null | awk '/git hash/ {next} /^kubelogin/ {print $2; exit}')" != "$${KUBELOGIN_VERSION}" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/kubelogin.zip" \
    "https://github.com/Azure/kubelogin/releases/download/$${KUBELOGIN_VERSION}/kubelogin-linux-$${ARCH}.zip"
  unzip -q "$tmp/kubelogin.zip" -d "$tmp"
  install -m 0755 "$tmp/bin/linux_$${ARCH}/kubelogin" /usr/local/bin/kubelogin
  rm -rf "$tmp"
fi

# Debian ships fd-find as `fdfind`; most users expect `fd`.
if [[ -x /usr/bin/fdfind && ! -e /usr/local/bin/fd ]]; then
  ln -s /usr/bin/fdfind /usr/local/bin/fd
fi

# Debian ships bat as `batcat`; link to `bat`.
if [[ -x /usr/bin/batcat && ! -e /usr/local/bin/bat ]]; then
  ln -s /usr/bin/batcat /usr/local/bin/bat
fi

########################################
# 6. user
########################################
phase "6/10 user setup ($VM_USER)"

# NOTE: OS Login is authoritative for interactive SSH. This local user
# exists so dotfiles, kubeconfig, and shell state have a stable home.
# Operators SSH'ing via `gcloud compute ssh` will land as their own
# OS Login user (e.g. `sa_NNN` / `user_example_com`), then can `sudo -iu
# ${vm_username}` to assume this persona. The refresh-kubeconfigs script
# targets this user explicitly.
if ! id "$VM_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/bin/zsh -G docker,sudo "$VM_USER"
fi

# Passwordless sudo for the persona user (jump box use-case; access is
# already gated by IAP + IAM).
echo "$VM_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${vm_username}
chmod 0440 /etc/sudoers.d/90-${vm_username}

# Ensure membership in docker/sudo even if the user pre-existed.
usermod -aG docker,sudo "$VM_USER"

USER_HOME="$(getent passwd "$VM_USER" | cut -d: -f6)"

########################################
# 7. dotfiles
########################################
phase "7/10 dotfiles"

DOTFILES_DIR="$USER_HOME/.dotfiles"

if [[ "$DOTFILES_REPO" == *"REPLACE-ME"* ]]; then
  log "dotfiles_repo is still the placeholder; skipping clone. Override terraform var 'dotfiles_repo' to enable."
else
  if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    sudo -u "$VM_USER" git clone --branch "$DOTFILES_BRANCH" "$DOTFILES_REPO" "$DOTFILES_DIR" || \
      log "dotfiles clone failed — continuing"
  else
    sudo -u "$VM_USER" git -C "$DOTFILES_DIR" fetch --all --prune || true
    sudo -u "$VM_USER" git -C "$DOTFILES_DIR" checkout "$DOTFILES_BRANCH" || true
    sudo -u "$VM_USER" git -C "$DOTFILES_DIR" pull --ff-only || true
  fi

  if [[ -d "$DOTFILES_DIR" ]]; then
    if [[ -x "$DOTFILES_DIR/install.sh" ]]; then
      log "running dotfiles install.sh"
      sudo -u "$VM_USER" bash -lc "cd '$DOTFILES_DIR' && ./install.sh" || log "install.sh returned non-zero"
    else
      # Fallback: treat top-level dirs as stow packages.
      log "no install.sh; attempting stow of top-level packages"
      pushd "$DOTFILES_DIR" >/dev/null
      for pkg in */ ; do
        pkg="$${pkg%/}"
        [[ "$pkg" == ".git" ]] && continue
        sudo -u "$VM_USER" stow --target="$USER_HOME" --restow "$pkg" 2>/dev/null || \
          log "stow skipped package: $pkg"
      done
      popd >/dev/null
    fi
  fi
fi

########################################
# 8. federation (identity-token plumbing + federated-principals.json)
########################################
phase "8/10 federation wiring"

# /etc/mgmt/federated-principals.json is the single source of truth for
# "which AWS roles and Azure apps does this VM federate into?". The JSON
# body is rendered on the Terraform side (main.tf passes a jsonencode()
# result into this template) so shell never hand-assembles JSON.
#
# File is world-readable (0644): it only holds identifiers (role ARNs,
# client IDs, tenant IDs, subscription IDs). The ID tokens themselves
# live in /var/run/mgmt/ with tighter permissions, written by the
# systemd oneshot below.
install -d -m 0755 /etc/mgmt
cat >/etc/mgmt/federated-principals.json <<'FEDERATED_JSON'
${federated_principals_json}
FEDERATED_JSON
chown root:root /etc/mgmt/federated-principals.json
chmod 0644 /etc/mgmt/federated-principals.json

# Persona group — used for owning the token files so the VM user can
# read them but no-one else can. `useradd -m` in phase 6 created the
# user's primary group matching the username.
PERSONA_GROUP="$(id -gn "$VM_USER")"

# --- id-token writer ---
# Pulls a Google-signed OIDC ID token for the passed audience from the
# GCE metadata server and writes it to disk atomically. Called by the
# systemd oneshot at boot + every 50 min. Usage:
#   mgmt-write-id-token <audience> <dest-file>
cat >/usr/local/sbin/mgmt-write-id-token <<'WRITER'
#!/usr/bin/env bash
# mgmt-write-id-token AUDIENCE DEST
#
# Fetch an ID token for AUDIENCE from the GCE metadata server and
# atomically replace DEST with it. Owner stays root; group inherited
# from whatever owns the parent directory (systemd RuntimeDirectory
# sets this to root:<persona-group> via /etc/tmpfiles-style perms we
# set in the service unit).
set -euo pipefail

aud="$${1:?audience required}"
dst="$${2:?dest path required}"

tmp="$(mktemp "$${dst}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# format=full: JWT with the full claim set (sub = SA unique_id which
# the AWS/Azure trust policies check). Without it you get an opaque
# access token that STS/AAD will not accept.
http_code="$(curl -sS -o "$tmp" -w '%%{http_code}' \
  -H 'Metadata-Flavor: Google' \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=$${aud}&format=full")"

if [[ "$http_code" != "200" ]]; then
  echo "metadata server returned HTTP $http_code fetching token for $aud" >&2
  exit 1
fi

# Basic sanity — the token is a JWT (three dot-separated segments).
if [[ "$(tr -cd '.' < "$tmp" | wc -c)" -ne 2 ]]; then
  echo "response for $aud is not a JWT" >&2
  exit 1
fi

# Preserve dest ownership/mode if it already exists; otherwise create
# 0640 root:<group-of-parent-dir>.
if [[ -e "$dst" ]]; then
  chmod --reference="$dst" "$tmp"
  chown --reference="$dst" "$tmp"
else
  parent="$(dirname "$dst")"
  chmod 0640 "$tmp"
  chown "root:$(stat -c '%G' "$parent")" "$tmp"
fi

mv -f "$tmp" "$dst"
trap - EXIT
WRITER
chmod 0755 /usr/local/sbin/mgmt-write-id-token

# --- systemd service + timer ---
# RuntimeDirectory=mgmt gives us a fresh /var/run/mgmt owned by
# root:$PERSONA_GROUP on every boot, so the persona user can read the
# token files without us having to manage the directory by hand.
cat >/etc/systemd/system/mgmt-gcp-id-token.service <<SERVICE
[Unit]
Description=Refresh GCP-signed ID tokens for AWS and Azure federation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# RuntimeDirectory creates /var/run/mgmt; Group sets the group for it.
# RuntimeDirectoryPreserve=yes is REQUIRED for Type=oneshot: default
# behaviour ("no") deletes /run/mgmt the moment ExecStart returns, which
# would orphan the AWS web_identity_token_file and Azure
# AZURE_FEDERATED_TOKEN_FILE paths within milliseconds of each refresh.
# "yes" keeps the directory across service stops; the timer's next
# OnUnitActiveSec fire-up just rewrites the token files in place.
RuntimeDirectory=mgmt
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
Group=$${PERSONA_GROUP}
ExecStart=/usr/local/sbin/mgmt-write-id-token sts.amazonaws.com /var/run/mgmt/gcp-id-token-aws
ExecStart=/usr/local/sbin/mgmt-write-id-token api://AzureADTokenExchange /var/run/mgmt/gcp-id-token-azure
# Run as root so ExecStart can write into /var/run/mgmt regardless of
# how the directory was created. Token files end up 0640 root:$${PERSONA_GROUP}.
User=root

[Install]
WantedBy=multi-user.target
SERVICE

cat >/etc/systemd/system/mgmt-gcp-id-token.timer <<'TIMER'
[Unit]
Description=Periodically refresh GCP-signed ID tokens (AWS + Azure federation)

[Timer]
# GCP ID tokens are valid 1h. Refresh at boot and every 50 min so
# kubectl calls never see an expired token-file.
OnBootSec=10s
OnUnitActiveSec=50min
Unit=mgmt-gcp-id-token.service
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable mgmt-gcp-id-token.timer
systemctl start mgmt-gcp-id-token.timer

# Run the oneshot synchronously now so refresh-kubeconfigs below has
# fresh token files on first boot. Without this the first refresh
# races the timer's OnBootSec=10s delay.
if ! systemctl start mgmt-gcp-id-token.service; then
  log "mgmt-gcp-id-token.service failed on first run — AWS/Azure refresh will fail until it succeeds"
fi

# --- ~/.aws/config (per-label profiles) ---
# One profile per aws_role_arns entry. web_identity_token_file points at
# the file the systemd oneshot writes, so the AWS SDK re-reads it on
# every credential refresh (keeps persistent kubectl sessions alive
# past the 1h STS credential lifetime).
#
# We pick us-east-1 as the default region for each profile. The
# refresh-kubeconfigs Azure/AWS loops iterate var.aws_regions explicitly
# via --region, so the profile default only matters for ad-hoc `aws ...`
# commands the operator runs directly.
install -d -o "$VM_USER" -g "$PERSONA_GROUP" -m 0700 "$USER_HOME/.aws"
AWS_CFG="$USER_HOME/.aws/config"
: > "$AWS_CFG"
jq -r '.aws_role_arns | to_entries[] | "\(.key)\t\(.value)"' /etc/mgmt/federated-principals.json | \
while IFS=$'\t' read -r label role_arn; do
  [[ -z "$label" ]] && continue
  cat >>"$AWS_CFG" <<PROFILE
[profile mgmt-vm-$${label}]
role_arn                = $${role_arn}
web_identity_token_file = /var/run/mgmt/gcp-id-token-aws
duration_seconds        = 3600
region                  = us-east-1
role_session_name       = mgmt-vm-$${label}

PROFILE
done
chown "$VM_USER:$PERSONA_GROUP" "$AWS_CFG"
chmod 0600 "$AWS_CFG"

# --- /etc/profile.d/mgmt-azure-federated.sh ---
# kubelogin's workload-identity mode reads these env vars at token-mint
# time, so we have to pick one (client_id, tenant_id) pair as the
# session default. The env-var contract does not support per-cluster
# overrides — if the operator has AKS clusters in multiple tenants they
# have to override $AZURE_TENANT_ID / $AZURE_CLIENT_ID before `kubectl`
# or use `az login --identity` with a different federated credential.
AZURE_PROFILE_D=/etc/profile.d/mgmt-azure-federated.sh
AZ_FIRST_LABEL="$(jq -r '.azure_federated_apps | to_entries | (.[0].key // "")' /etc/mgmt/federated-principals.json)"
AZ_FIRST_CLIENT_ID="$(jq -r '.azure_federated_apps | to_entries | (.[0].value.client_id // "")' /etc/mgmt/federated-principals.json)"
AZ_FIRST_TENANT_ID="$(jq -r '.azure_federated_apps | to_entries | (.[0].value.tenant_id // "")' /etc/mgmt/federated-principals.json)"
AZ_LABEL_COUNT="$(jq -r '.azure_federated_apps | length' /etc/mgmt/federated-principals.json)"

{
  echo "# Managed by /etc/mgmt/bootstrap.sh. Do not edit by hand."
  echo "# Azure workload-identity env vars consumed by kubelogin -l workloadidentity."
  echo "export AZURE_FEDERATED_TOKEN_FILE=/var/run/mgmt/gcp-id-token-azure"
  echo "export AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/"
  echo "export AZURE_CLIENT_ID='$${AZ_FIRST_CLIENT_ID}'"
  echo "export AZURE_TENANT_ID='$${AZ_FIRST_TENANT_ID}'"
  if [[ "$AZ_LABEL_COUNT" -gt 1 ]]; then
    echo "# NOTE: $${AZ_LABEL_COUNT} azure_federated_apps entries detected."
    echo "# The default exports above point at '$${AZ_FIRST_LABEL}'. To hit another tenant,"
    echo "# override AZURE_CLIENT_ID and AZURE_TENANT_ID in your shell before kubectl:"
    echo "#   export AZURE_CLIENT_ID=<client-id-from-federated-principals.json>"
    echo "#   export AZURE_TENANT_ID=<tenant-id-from-federated-principals.json>"
  fi
} > "$AZURE_PROFILE_D"
chmod 0644 "$AZURE_PROFILE_D"

########################################
# 9. kubeconfig refresh
########################################
phase "9/10 kubeconfig refresh script"

install -d -m 0755 /usr/local/bin
cat >/usr/local/bin/refresh-kubeconfigs <<'REFRESH'
#!/usr/bin/env bash
# refresh-kubeconfigs
#
# Discover every Kubernetes cluster the mgmt VM has access to across
# GCP / AWS / Azure and merge credentials into the invoking user's
# ~/.kube/config. Each block is tolerant of the others: AWS CLI
# errors do not abort the Azure loop, and vice versa.
#
# Context aliases are normalised to "<cloud>-<label>-<cluster>":
#   gke-<project>-<cluster>        (GCP — label == project ID)
#   aws-<label>-<cluster>          (AWS — label from aws_role_arns key)
#   azure-<label>-<cluster>        (Azure — label from azure_federated_apps key)
# This prevents collisions between clusters with the same short name
# across clouds (e.g. two "sec-lab" clusters in GKE + EKS).
#
# Usage:
#   refresh-kubeconfigs              # for current user
#   refresh-kubeconfigs --preflight  # diagnostics only; no kubeconfig writes
#   sudo -iu devops refresh-kubeconfigs
#
# NOTE: this script depends on env vars exported by
# /etc/profile.d/mgmt-azure-federated.sh for kubelogin's workloadidentity
# mode. profile.d only fires for login shells, so the Azure block
# explicitly sources that file when invoked from cron, systemd, or
# `sudo -u <user> bash` non-login paths.

set -euo pipefail

CONFIG=/etc/mgmt/federated-principals.json

if ! command -v gcloud >/dev/null; then
  echo "gcloud not on PATH" >&2; exit 1
fi
if ! command -v gke-gcloud-auth-plugin >/dev/null; then
  echo "gke-gcloud-auth-plugin not installed" >&2; exit 1
fi
if ! command -v jq >/dev/null; then
  echo "jq not on PATH" >&2; exit 1
fi

# ---------------------------------------------------------------------
# preflight_main — diagnostics-only mode. Triggered by `--preflight`.
# Prints egress IP and TCP-reachability of each cluster's API endpoint
# across GKE / EKS / AKS, plus a summary noting whether the egress IP
# is in each cluster's authorized_cidrs allow-list. Does NOT modify
# ~/.kube/config and does NOT call kubelogin / gcloud get-credentials.
# Each cloud block is independently fault-tolerant — one cloud being
# entirely down does not abort the others.
# ---------------------------------------------------------------------
preflight_main() {
  local egress_ip="unknown"
  egress_ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || echo unknown)"
  echo "[preflight] egress IP: $${egress_ip}"

  local reachable=0 unreachable=0
  # cidr_summary accumulates per-cluster authorized-CIDR membership notes
  # so the final line can call out whichever cluster the operator most
  # likely needs to update.
  local cidr_summary=""

  # --- GKE ---
  if [[ -f "$CONFIG" ]] && command -v gcloud >/dev/null; then
    echo "[preflight] GKE: enumerating projects..."
    local projects
    mapfile -t projects < <(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
    local proj name loc endpoint cidrs in_cidrs
    for proj in "$${projects[@]}"; do
      [[ -z "$proj" ]] && continue
      while IFS=$'\t' read -r name loc endpoint cidrs; do
        [[ -z "$name" ]] && continue
        if timeout 5 bash -c "</dev/tcp/$${endpoint}/443" 2>/dev/null; then
          echo "  [reachable]   gke $${proj}/$${name} ($${endpoint}:443)"
          reachable=$((reachable + 1))
        else
          echo "  [unreachable] gke $${proj}/$${name} ($${endpoint}:443)"
          unreachable=$((unreachable + 1))
        fi
        in_cidrs="not-checked"
        if [[ -n "$cidrs" && "$cidrs" != "None" ]]; then
          if preflight_ip_in_cidrs "$egress_ip" "$cidrs"; then
            in_cidrs="present"
          else
            in_cidrs="ABSENT"
            cidr_summary="$${cidr_summary} $${name}=ABSENT"
          fi
          echo "    authorized_cidrs ($${in_cidrs}): $${cidrs}"
        fi
      done < <(
        gcloud container clusters list \
          --project="$proj" \
          --format='value(name,location,endpoint,masterAuthorizedNetworksConfig.cidrBlocks.cidrBlock.list())' \
          2>/dev/null || true
      )
    done
  fi

  # --- AWS / EKS ---
  if [[ -f "$CONFIG" ]] && command -v aws >/dev/null; then
    local aws_count
    aws_count="$(jq -r '.aws_role_arns | length' "$CONFIG")"
    if [[ "$aws_count" -gt 0 ]]; then
      local regions
      mapfile -t regions < <(jq -r '.aws_regions[]?' "$CONFIG")
      if [[ $${#regions[@]} -eq 0 ]]; then
        regions=(us-east-1 us-west-2)
        echo "[preflight] AWS: aws_regions empty — falling back to $${regions[*]}"
      fi
      local label role_arn region cluster ep cidrs host
      while IFS=$'\t' read -r label role_arn; do
        [[ -z "$label" ]] && continue
        for region in "$${regions[@]}"; do
          [[ -z "$region" ]] && continue
          local clusters
          mapfile -t clusters < <(
            AWS_PROFILE="mgmt-vm-$${label}" aws eks list-clusters \
              --region "$region" --query 'clusters[]' --output text \
              2>/dev/null | tr '\t' '\n' || true
          )
          for cluster in "$${clusters[@]}"; do
            [[ -z "$cluster" ]] && continue
            ep="$(AWS_PROFILE="mgmt-vm-$${label}" aws eks describe-cluster \
              --region "$region" --name "$cluster" \
              --query 'cluster.endpoint' --output text 2>/dev/null || true)"
            cidrs="$(AWS_PROFILE="mgmt-vm-$${label}" aws eks describe-cluster \
              --region "$region" --name "$cluster" \
              --query 'cluster.resourcesVpcConfig.publicAccessCidrs' \
              --output text 2>/dev/null || true)"
            if [[ -z "$ep" || "$ep" == "None" ]]; then
              echo "  [unreachable] eks $${label}/$${region}/$${cluster} (no endpoint returned)"
              unreachable=$((unreachable + 1))
              continue
            fi
            host="$${ep#https://}"
            host="$${host%%/*}"
            if timeout 5 bash -c "</dev/tcp/$${host}/443" 2>/dev/null; then
              echo "  [reachable]   eks $${label}/$${region}/$${cluster} ($${host}:443)"
              reachable=$((reachable + 1))
            else
              echo "  [unreachable] eks $${label}/$${region}/$${cluster} ($${host}:443)"
              unreachable=$((unreachable + 1))
            fi
            if [[ -n "$cidrs" && "$cidrs" != "None" ]]; then
              if preflight_ip_in_cidrs "$egress_ip" "$cidrs"; then
                echo "    authorized_cidrs (present): $${cidrs}"
              else
                echo "    authorized_cidrs (ABSENT): $${cidrs}"
                cidr_summary="$${cidr_summary} $${cluster}=ABSENT"
              fi
            fi
          done
        done
      done < <(jq -r '.aws_role_arns | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG")
    fi
  fi

  # --- Azure / AKS ---
  [[ -r /etc/profile.d/mgmt-azure-federated.sh ]] && . /etc/profile.d/mgmt-azure-federated.sh
  if [[ -f "$CONFIG" ]] && command -v az >/dev/null; then
    local az_count
    az_count="$(jq -r '.azure_federated_apps | length' "$CONFIG")"
    if [[ "$az_count" -gt 0 ]]; then
      local AZ_TOKEN_FILE="/var/run/mgmt/gcp-id-token-azure"
      local label client_id tenant_id sub name fqdn cidrs
      while IFS=$'\t' read -r label client_id tenant_id; do
        [[ -z "$label" ]] && continue
        if [[ ! -r "$AZ_TOKEN_FILE" ]]; then
          echo "[preflight] AKS: $${AZ_TOKEN_FILE} not readable — skipping label=$${label}"
          continue
        fi
        if ! az login --service-principal \
               --username "$client_id" \
               --tenant "$tenant_id" \
               --federated-token-file "$AZ_TOKEN_FILE" \
               --output none 2>/dev/null; then
          echo "[preflight] AKS: az login failed for $${label} — skipping"
          continue
        fi
        local subs
        mapfile -t subs < <(jq -r --arg l "$label" '.azure_federated_apps[$l].subscription_ids[]?' "$CONFIG")
        if [[ $${#subs[@]} -eq 0 ]]; then
          mapfile -t subs < <(az account list --query '[].id' -o tsv 2>/dev/null || true)
        fi
        for sub in "$${subs[@]}"; do
          [[ -z "$sub" ]] && continue
          az account set --subscription "$sub" 2>/dev/null || continue
          while IFS=$'\t' read -r name fqdn cidrs; do
            [[ -z "$name" ]] && continue
            if [[ -z "$fqdn" || "$fqdn" == "None" ]]; then
              echo "  [unreachable] aks $${label}/$${sub}/$${name} (no fqdn)"
              unreachable=$((unreachable + 1))
              continue
            fi
            if timeout 5 bash -c "</dev/tcp/$${fqdn}/443" 2>/dev/null; then
              echo "  [reachable]   aks $${label}/$${sub}/$${name} ($${fqdn}:443)"
              reachable=$((reachable + 1))
            else
              echo "  [unreachable] aks $${label}/$${sub}/$${name} ($${fqdn}:443)"
              unreachable=$((unreachable + 1))
            fi
            if [[ -n "$cidrs" && "$cidrs" != "None" ]]; then
              if preflight_ip_in_cidrs "$egress_ip" "$cidrs"; then
                echo "    authorized_cidrs (present): $${cidrs}"
              else
                echo "    authorized_cidrs (ABSENT): $${cidrs}"
                cidr_summary="$${cidr_summary} $${name}=ABSENT"
              fi
            fi
          done < <(
            az aks list \
              --query '[].[name, fqdn, join('"'"','"'"', apiServerAccessProfile.authorizedIpRanges || `[]`)]' \
              -o tsv 2>/dev/null || true
          )
        done
      done < <(jq -r '.azure_federated_apps | to_entries[] | "\(.key)\t\(.value.client_id)\t\(.value.tenant_id)"' "$CONFIG")
    fi
  fi

  local cidr_msg="not in any checked authorized_cidrs"
  if [[ -z "$cidr_summary" ]]; then
    cidr_msg="present in (or unconstrained by) all checked authorized_cidrs"
  else
    cidr_msg="missing from authorized_cidrs of:$${cidr_summary}"
  fi
  echo "[preflight] $${reachable} reachable / $${unreachable} unreachable. Egress IP $${egress_ip} $${cidr_msg}."
}

# preflight_ip_in_cidrs IP CIDR_LIST
# Returns 0 if IP appears anywhere in CIDR_LIST (whitespace- or
# comma-separated). Pure substring match — no real CIDR arithmetic — so
# a /32 hit is exact and a wider range like 1.2.3.0/24 will only match
# if the operator wrote 1.2.3.0/24 verbatim. That's intentional: the
# preflight is a hint, not authoritative validation. False negatives
# print "ABSENT" and prompt the operator to eyeball the printed list.
preflight_ip_in_cidrs() {
  local ip="$1"
  local list="$2"
  local entry
  for entry in $${list//,/ }; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == "$ip" || "$entry" == "$${ip}/32" || "$entry" == "0.0.0.0/0" ]]; then
      return 0
    fi
  done
  return 1
}

case "$${1:-}" in
  --preflight) preflight_main; exit 0 ;;
esac

export USE_GKE_GCLOUD_AUTH_PLUGIN=True
mkdir -p "$HOME/.kube"
touch "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

# -------- GCP (GKE) --------
echo "[refresh-kubeconfigs] GCP: listing projects..."
mapfile -t PROJECTS < <(gcloud projects list --format='value(projectId)' 2>/dev/null || true)

if [[ $${#PROJECTS[@]} -eq 0 ]]; then
  echo "[refresh-kubeconfigs] GCP: no projects visible — check IAM bindings"
fi

for proj in "$${PROJECTS[@]}"; do
  echo "[refresh-kubeconfigs] GCP project: $proj"
  # Some projects don't have the container API enabled — ignore errors.
  mapfile -t CLUSTERS < <(
    gcloud container clusters list \
      --project="$proj" \
      --format='value(name,location)' 2>/dev/null || true
  )
  for row in "$${CLUSTERS[@]}"; do
    [[ -z "$row" ]] && continue
    name="$(awk '{print $1}' <<<"$row")"
    loc="$(awk '{print $2}' <<<"$row")"
    echo "  -> $name ($loc)"
    # location may be a zone (a-b-c) or region (a-b); get-credentials
    # accepts --zone or --region accordingly.
    if [[ "$loc" == *-*-* ]]; then
      gcloud container clusters get-credentials "$name" \
        --project="$proj" --zone="$loc" >/dev/null || \
        { echo "    !! get-credentials failed for $name"; continue; }
    else
      gcloud container clusters get-credentials "$name" \
        --project="$proj" --region="$loc" >/dev/null || \
        { echo "    !! get-credentials failed for $name"; continue; }
    fi
    # Rename to match the aws-/azure- convention. gcloud's default
    # context name is gke_<proj>_<loc>_<name>; two clusters named the
    # same across GCP/AWS/Azure would otherwise be indistinguishable
    # only by prefix underscore vs dash.
    old_ctx="gke_$${proj}_$${loc}_$${name}"
    new_ctx="gke-$${proj}-$${name}"
    if kubectl config get-contexts -o name | grep -qx "$old_ctx"; then
      kubectl config rename-context "$old_ctx" "$new_ctx" >/dev/null || true
    fi
  done
done

# -------- AWS (EKS) --------
# Discovery only — credentials are provided by the ~/.aws/config profile
# (web_identity_token_file) populated during bootstrap, refreshed by the
# mgmt-gcp-id-token.timer systemd unit. We do NOT assume-role inline
# here; env-var credentials would vanish the moment this script exits.
if [[ -f "$CONFIG" ]] && command -v aws >/dev/null; then
  AWS_LABELS_COUNT="$(jq -r '.aws_role_arns | length' "$CONFIG")"
  if [[ "$AWS_LABELS_COUNT" -gt 0 ]]; then
    mapfile -t AWS_REGIONS < <(jq -r '.aws_regions[]?' "$CONFIG")
    if [[ $${#AWS_REGIONS[@]} -eq 0 ]]; then
      echo "[refresh-kubeconfigs] AWS: aws_regions is empty in $CONFIG — skipping"
    else
      while IFS=$'\t' read -r label role_arn; do
        [[ -z "$label" ]] && continue
        echo "[refresh-kubeconfigs] AWS: label=$label role=$role_arn"
        for region in "$${AWS_REGIONS[@]}"; do
          [[ -z "$region" ]] && continue
          mapfile -t EKS_CLUSTERS < <(
            AWS_PROFILE="mgmt-vm-$${label}" aws eks list-clusters \
              --region "$region" \
              --query 'clusters[]' \
              --output text 2>/dev/null || true
          )
          for c in "$${EKS_CLUSTERS[@]}"; do
            [[ -z "$c" ]] && continue
            echo "  -> $c ($region)"
            AWS_PROFILE="mgmt-vm-$${label}" aws eks update-kubeconfig \
              --region "$region" \
              --name "$c" \
              --alias "aws-$${label}-$${c}" >/dev/null || \
              echo "    !! update-kubeconfig failed for $c in $region"
          done
        done
      done < <(jq -r '.aws_role_arns | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG")
    fi
  else
    echo "[refresh-kubeconfigs] AWS: no aws_role_arns configured — skipping"
  fi
else
  [[ ! -f "$CONFIG" ]]      && echo "[refresh-kubeconfigs] AWS: $CONFIG missing — skipping"
  ! command -v aws >/dev/null && echo "[refresh-kubeconfigs] AWS: aws CLI missing — skipping"
fi

# -------- Azure (AKS) --------
# Same story as AWS: discovery only. kubelogin is wired in
# workload-identity mode via /etc/profile.d/mgmt-azure-federated.sh so
# it reads AZURE_FEDERATED_TOKEN_FILE + AZURE_CLIENT_ID + AZURE_TENANT_ID
# on every kubectl call — no az login/logout here.
#
# For each label, we iterate subscription_ids if provided, otherwise
# fall back to `az account list`. `az login --federated-token` is
# required because az reads credentials from its own cache (not the
# env vars kubelogin uses); we perform it once per label with a fresh
# token from the systemd-managed file.
# profile.d only fires for login shells; explicit source for cron/systemd/non-login sudo paths.
[[ -r /etc/profile.d/mgmt-azure-federated.sh ]] && . /etc/profile.d/mgmt-azure-federated.sh

if [[ -f "$CONFIG" ]] && command -v az >/dev/null && command -v kubelogin >/dev/null; then
  AZ_LABELS_COUNT="$(jq -r '.azure_federated_apps | length' "$CONFIG")"
  if [[ "$AZ_LABELS_COUNT" -gt 0 ]]; then
    AZ_TOKEN_FILE="/var/run/mgmt/gcp-id-token-azure"
    while IFS=$'\t' read -r label client_id tenant_id; do
      [[ -z "$label" ]] && continue
      echo "[refresh-kubeconfigs] Azure: label=$label tenant=$tenant_id"

      if [[ ! -r "$AZ_TOKEN_FILE" ]]; then
        echo "  !! $AZ_TOKEN_FILE not readable — check mgmt-gcp-id-token.timer; skipping $label"
        continue
      fi

      # Federated login. The token is short-lived but the az cache
      # persists the resulting session, so we re-login each refresh.
      # --federated-token-file (NOT --federated-token "$(cat ...)") keeps
      # the JWT off the process command line, where any local user could
      # read it from /proc/<pid>/cmdline. Requires az CLI >= 2.62 (the
      # packages.microsoft.com build is well past that floor).
      if ! az login --service-principal \
             --username "$client_id" \
             --tenant "$tenant_id" \
             --federated-token-file "$AZ_TOKEN_FILE" \
             --output none 2>/dev/null; then
        echo "  !! az login failed for $label — skipping"
        continue
      fi

      # Subscriptions: explicit list from config, else fall back to
      # whatever the federated principal can see.
      mapfile -t SUBS < <(jq -r --arg l "$label" '.azure_federated_apps[$l].subscription_ids[]?' "$CONFIG")
      if [[ $${#SUBS[@]} -eq 0 ]]; then
        mapfile -t SUBS < <(az account list --query '[].id' -o tsv 2>/dev/null || true)
      fi

      if [[ $${#SUBS[@]} -eq 0 ]]; then
        echo "  !! no subscriptions visible for $label"
        continue
      fi

      for sub in "$${SUBS[@]}"; do
        [[ -z "$sub" ]] && continue
        az account set --subscription "$sub" 2>/dev/null || {
          echo "  !! az account set failed for sub=$sub"; continue;
        }
        mapfile -t AKS_ROWS < <(az aks list --query '[].{n:name,g:resourceGroup}' -o tsv 2>/dev/null || true)
        for row in "$${AKS_ROWS[@]}"; do
          [[ -z "$row" ]] && continue
          name="$(awk '{print $1}' <<<"$row")"
          rg="$(awk '{print $2}' <<<"$row")"
          echo "  -> $name ($rg in sub $sub)"
          az aks get-credentials \
            --name "$name" \
            --resource-group "$rg" \
            --subscription "$sub" \
            --context "azure-$${label}-$${name}" \
            --overwrite-existing >/dev/null || {
              echo "    !! get-credentials failed for $name"
              continue
            }
        done
      done
    done < <(jq -r '.azure_federated_apps | to_entries[] | "\(.key)\t\(.value.client_id)\t\(.value.tenant_id)"' "$CONFIG")

    # Convert any azurecli-mode entries to workloadidentity-mode so
    # kubelogin reads env vars instead of calling `az` at token time.
    # Safe to run repeatedly; a no-op for contexts that are already
    # in workloadidentity mode.
    kubelogin convert-kubeconfig -l workloadidentity >/dev/null || \
      echo "[refresh-kubeconfigs] Azure: kubelogin convert-kubeconfig failed (non-fatal)"
  else
    echo "[refresh-kubeconfigs] Azure: no azure_federated_apps configured — skipping"
  fi
else
  [[ ! -f "$CONFIG" ]]                && echo "[refresh-kubeconfigs] Azure: $CONFIG missing — skipping"
  ! command -v az >/dev/null          && echo "[refresh-kubeconfigs] Azure: az CLI missing — skipping"
  ! command -v kubelogin >/dev/null   && echo "[refresh-kubeconfigs] Azure: kubelogin missing — skipping"
fi

echo "[refresh-kubeconfigs] done. Contexts:"
kubectl config get-contexts -o name || true
REFRESH
chmod 0755 /usr/local/bin/refresh-kubeconfigs

# Prime kubeconfig for the persona user on first boot.
# Uses the VM's attached SA via ADC — no keys needed.
if [[ ! -f "$STATE_DIR/kubeconfig-primed" ]]; then
  log "priming kubeconfig for $VM_USER"
  sudo -iu "$VM_USER" bash -lc '/usr/local/bin/refresh-kubeconfigs' || \
    log "initial kubeconfig refresh failed — run manually later"
  touch "$STATE_DIR/kubeconfig-primed"
fi

########################################
# 10. done
########################################
phase "10/10 done"
date -Is > "$SENTINEL"
log "bootstrap complete"
