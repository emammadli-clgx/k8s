#!/bin/bash

#===============================================================================
# PHASE 1: PREREQUISITES SETUP (Vagrant Version)
# Sets up the basic environment and installs required packages
# Run from: vagrant/ directory
#===============================================================================

set -euo pipefail

# Get script directory and load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
}

# Check if running from vagrant directory
if [[ ! -f "Vagrantfile" ]]; then
    log_error "This script must be run from the vagrant/ directory"
    exit 1
fi

# Check if Vagrant is available
if ! command -v vagrant >/dev/null 2>&1; then
    log_error "Vagrant command not found"
    exit 1
fi

log "=== Phase 1: Prerequisites Setup ==="

# Helper function to run commands on VMs via vagrant ssh
run_on_vm() {
    local vm="$1"
    local command="$2"
    
    log "Executing on $vm: $command"
    if vagrant ssh "$vm" -c "$command"; then
        log_success "Command completed on $vm"
        return 0
    else
        log_error "Command failed on $vm"
        return 1
    fi
}

# Helper function to run commands on all nodes
run_on_all_nodes() {
    local command="$1"
    local failed_nodes=()
    
    log "Running command on all nodes: $command"
    
    for vm in master-1 master-2 worker-1 worker-2; do
        if ! run_on_vm "$vm" "$command"; then
            failed_nodes+=("$vm")
        fi
    done
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_error "Command failed on nodes: ${failed_nodes[*]}"
        return 1
    fi
    
    return 0
}

# Update system packages
log "Updating system packages on all nodes..."
if run_on_all_nodes "sudo apt-get update && sudo apt-get upgrade -y"; then
    log_success "System packages updated on all nodes"
else
    log_error "Failed to update system packages"
    exit 1
fi

# Install basic packages
log "Installing basic packages on all nodes..."
basic_packages="wget curl vim htop net-tools socat conntrack ipset"

if run_on_all_nodes "sudo apt-get install -y $basic_packages"; then
    log_success "Basic packages installed on all nodes"
else
    log_error "Failed to install basic packages"
    exit 1
fi

# Disable swap on all nodes
log "Disabling swap on all nodes..."
disable_swap_commands="sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

if run_on_all_nodes "$disable_swap_commands"; then
    log_success "Swap disabled on all nodes"
else
    log_error "Failed to disable swap"
    exit 1
fi

# Install containerd on all nodes
log "Installing containerd on all nodes..."

# Download and install containerd
install_containerd_script='
sudo mkdir -p /tmp/k8s-install
cd /tmp/k8s-install

# Download containerd
wget -q https://github.com/containerd/containerd/releases/download/v'${CONTAINERD_VERSION}'/containerd-'${CONTAINERD_VERSION}'-linux-amd64.tar.gz

# Extract and install containerd
sudo tar -C /usr/local -xzf containerd-'${CONTAINERD_VERSION}'-linux-amd64.tar.gz

# Download runc
wget -q https://github.com/opencontainers/runc/releases/download/'${RUNC_VERSION}'/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# Download CNI plugins  
wget -q https://github.com/containernetworking/plugins/releases/download/'${CNI_VERSION}'/cni-plugins-linux-amd64-'${CNI_VERSION}'.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-'${CNI_VERSION}'.tgz
'

if run_on_all_nodes "$install_containerd_script"; then
    log_success "Containerd installed on all nodes"
else
    log_error "Failed to install containerd"
    exit 1
fi

# Configure containerd
log "Configuring containerd on all nodes..."
configure_containerd_script='
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Enable SystemdCgroup
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# Create systemd service file
sudo tee /etc/systemd/system/containerd.service >/dev/null <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# Enable and start containerd
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd
'

if run_on_all_nodes "$configure_containerd_script"; then
    log_success "Containerd configured on all nodes"
else
    log_error "Failed to configure containerd"
    exit 1
fi

# Install crictl
log "Installing crictl on all nodes..."
install_crictl_script='
cd /tmp/k8s-install
wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/'${CRICTL_VERSION}'/crictl-'${CRICTL_VERSION}'-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf crictl-'${CRICTL_VERSION}'-linux-amd64.tar.gz

# Configure crictl
sudo tee /etc/crictl.yaml >/dev/null <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 2
debug: false
pull-image-on-create: false
EOF
'

if run_on_all_nodes "$install_crictl_script"; then
    log_success "crictl installed on all nodes"
else
    log_error "Failed to install crictl"
    exit 1
fi

# Configure kernel modules and sysctls
log "Configuring kernel modules and sysctl parameters..."
configure_kernel_script='
# Load kernel modules
sudo tee /etc/modules-load.d/containerd.conf >/dev/null <<EOF
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system >/dev/null
'

if run_on_all_nodes "$configure_kernel_script"; then
    log_success "Kernel configuration completed on all nodes"
else
    log_error "Failed to configure kernel"
    exit 1
fi

# Verify installations
log "Verifying installations on all nodes..."
verify_script='
echo "=== Verification Results ==="
echo "Containerd version:"
containerd --version
echo ""
echo "Runc version:"
runc --version | head -1
echo ""
echo "crictl version:"
crictl --version
echo ""
echo "Containerd status:"
sudo systemctl is-active containerd
echo ""
echo "Available CNI plugins:"
ls -la /opt/cni/bin/ | wc -l
echo " plugins installed"
'

log "Running verification on all nodes..."
for vm in master-1 master-2 worker-1 worker-2; do
    log "--- Verification results for $vm ---"
    run_on_vm "$vm" "$verify_script"
done

# Create status file to track completion
echo "phase1_completed=$(date)" > .phase1_status

log_success "Phase 1 (Prerequisites) completed successfully!"
log ""
log "Next step: Run ../phase2-certificates.sh"
log "This will generate all required SSL certificates"
