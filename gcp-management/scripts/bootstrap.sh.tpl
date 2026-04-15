#!/usr/bin/env bash
#
# Management VM bootstrap.
#
# Idempotent — safe to run on first boot and again as `sudo bash /etc/mgmt/bootstrap.sh`.
# Phases:
#   1. guardrails  (early exit if already green)
#   2. system      (apt update + base packages)
#   3. apt-repos   (HashiCorp, Docker, Google Cloud SDK, Helm, GitHub CLI, Kubernetes)
#   4. packages    (tooling install)
#   5. binaries    (tools without clean apt: terragrunt, k9s, yq, sops, age, fd symlink)
#   6. user        (create ${vm_username}, groups, shell)
#   7. dotfiles    (clone + install.sh or stow)
#   8. kubeconfig  (refresh-kubeconfigs script + first-run)
#   9. done        (touch sentinel, log completion)
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
phase "1/9 guardrails"
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
phase "2/9 system update + base"
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
phase "3/9 apt repositories"

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

apt-get update -y

########################################
# 4. packages
########################################
phase "4/9 package install"
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

systemctl enable --now docker

########################################
# 5. binaries (no clean apt)
########################################
phase "5/9 supplemental binaries"

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
phase "6/9 user setup ($VM_USER)"

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
phase "7/9 dotfiles"

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
# 8. kubeconfig refresh
########################################
phase "8/9 kubeconfig refresh script"

install -d -m 0755 /usr/local/bin
cat >/usr/local/bin/refresh-kubeconfigs <<'REFRESH'
#!/usr/bin/env bash
# refresh-kubeconfigs
#
# Discover every GKE cluster visible to the VM's service account and
# merge credentials into the invoking user's ~/.kube/config.
#
# Usage:
#   refresh-kubeconfigs              # for current user
#   sudo -iu devops refresh-kubeconfigs
set -euo pipefail

if ! command -v gcloud >/dev/null; then
  echo "gcloud not on PATH" >&2; exit 1
fi
if ! command -v gke-gcloud-auth-plugin >/dev/null; then
  echo "gke-gcloud-auth-plugin not installed" >&2; exit 1
fi

export USE_GKE_GCLOUD_AUTH_PLUGIN=True
mkdir -p "$HOME/.kube"
touch "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

echo "[refresh-kubeconfigs] listing projects..."
mapfile -t PROJECTS < <(gcloud projects list --format='value(projectId)' 2>/dev/null || true)

if [[ $${#PROJECTS[@]} -eq 0 ]]; then
  echo "[refresh-kubeconfigs] no projects visible — check IAM bindings" >&2
  exit 0
fi

for proj in "$${PROJECTS[@]}"; do
  echo "[refresh-kubeconfigs] project: $proj"
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
    # location may be a zone or region; get-credentials accepts either
    # via --zone or --region. --region form is tolerant of both on
    # recent gcloud.
    if [[ "$loc" == *-*-* ]]; then
      gcloud container clusters get-credentials "$name" \
        --project="$proj" --zone="$loc" >/dev/null || \
        echo "    !! get-credentials failed for $name"
    else
      gcloud container clusters get-credentials "$name" \
        --project="$proj" --region="$loc" >/dev/null || \
        echo "    !! get-credentials failed for $name"
    fi
  done
done

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
# 9. done
########################################
phase "9/9 done"
date -Is > "$SENTINEL"
log "bootstrap complete"
