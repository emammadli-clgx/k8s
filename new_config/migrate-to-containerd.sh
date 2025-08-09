#!/usr/bin/env bash
# Migrate a worker node from Docker (dockershim era) to pure containerd runtime.
# Safe to re-run; idempotent where practical.
# Tested on Ubuntu 22.04 (Jammy)
# Usage: sudo ./migrate-to-containerd.sh

set -euo pipefail

ARCH=$(uname -m)
CRICTL_VERSION="v1.30.0"
NERDCTL_VERSION="1.7.6"
CONTAINERD_PKG="containerd.io"            # From Docker repo; alternatively use distro containerd
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
LOG_PREFIX="[containerd-migration]"

log(){ echo "${LOG_PREFIX} $*"; }

die(){ echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }

add_repo_if_needed(){
  if [[ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
    log "Adding Docker (for containerd) apt repo key"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    log "Adding Docker apt repo"
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  fi
}

remove_docker(){
  log "Disabling docker services if present"
  systemctl disable --now docker.service docker.socket 2>/dev/null || true
  log "Removing docker packages (ignore errors if absent)"
  apt-get remove -y "${DOCKER_PKGS[@]}" 2>/dev/null || true
  apt-get autoremove -y || true
}

install_containerd(){
  if command -v containerd >/dev/null 2>&1; then
    log "containerd already installed: $(containerd --version)"
  else
    log "Installing containerd"
    add_repo_if_needed
    apt-get update
    apt-get install -y ${CONTAINERD_PKG}
  fi
}

configure_containerd(){
  mkdir -p /etc/containerd
  if [[ ! -s /etc/containerd/config.toml ]]; then
    log "Generating default containerd config"
    containerd config default > /etc/containerd/config.toml
  fi
  # Enable systemd cgroups
  if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    log "Switching SystemdCgroup to true"
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  fi
  # Ensure pause image accessible (optional - usually already defined under [plugins."io.containerd.grpc.v1.cri"])
  if ! grep -q 'sandbox_image' /etc/containerd/config.toml; then
    log "(Optional) Adding sandbox_image stanza placeholder"
    cat >> /etc/containerd/config.toml <<'EOF'
[plugins."io.containerd.grpc.v1.cri".sandbox_image]
# (Informational) override default pause image here if using a private registry.
EOF
  fi
}

kernel_settings(){
  log "Setting kernel modules & sysctl for Kubernetes networking"
  tee /etc/modules-load.d/containerd.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay || true
  modprobe br_netfilter || true
  tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null
}

restart_containerd(){
  systemctl enable containerd >/dev/null
  systemctl restart containerd
  sleep 2
  systemctl is-active --quiet containerd || die "containerd failed to start"
  log "containerd active"
}

install_crictl(){
  if command -v crictl >/dev/null 2>&1; then
    log "crictl already present: $(crictl --version 2>/dev/null || echo installed)"
    return
  fi
  local TARBALL="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  log "Installing crictl ${CRICTL_VERSION}"
  curl -fsSL -o /tmp/${TARBALL} https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${TARBALL}
  tar -C /usr/local/bin -xzf /tmp/${TARBALL}
  rm /tmp/${TARBALL}
  crictl config runtime-endpoint unix:///run/containerd/containerd.sock || true
}

install_nerdctl(){
  if command -v nerdctl >/dev/null 2>&1; then
    log "nerdctl already installed"
    return
  fi
  local TARBALL="nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz"
  log "Installing nerdctl ${NERDCTL_VERSION}"
  curl -fsSL -o /tmp/${TARBALL} https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${TARBALL}
  tar -C /usr/local/bin -xzf /tmp/${TARBALL} nerdctl
  rm /tmp/${TARBALL}
}

summary(){
  echo "\n${LOG_PREFIX} Migration complete"
  echo "Runtime info:"
  crictl info | grep -E 'runtimeType|version' || true
  containerd --version || true
  echo "Kubelet should be configured with --container-runtime-endpoint=unix:///run/containerd/containerd.sock (already in modern docs)."
}

main(){
  require_root
  log "Starting migration to containerd"
  remove_docker
  install_containerd
  configure_containerd
  kernel_settings
  restart_containerd
  install_crictl
  install_nerdctl
  summary
}

main "$@"
