#!/bin/bash
# Phase 1: Prerequisites Setup
# Run from: master-1 node

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $1${NC}"
}

run_on_node() {
    local node=$1
    local command=$2
    local description=$3
    
    log "[$node] $description..."
    
    if [[ "$node" == "master-1" ]]; then
        # Run locally on master-1
        if eval "$command" &>/dev/null; then
            log_success "[$node] $description completed"
            return 0
        else
            log_error "[$node] $description failed"
            return 1
        fi
    else
        # SSH to other nodes
        if ssh -o StrictHostKeyChecking=no vagrant@$node "$command" &>/dev/null; then
            log_success "[$node] $description completed"
            return 0
        else
            log_error "[$node] $description failed"
            return 1
        fi
    fi
}

run_on_all_nodes() {
    local command=$1
    local description=$2
    local nodes=("master-1" "master-2" "worker-1" "worker-2")
    local failed=()
    
    log "Running on all nodes: $description"
    
    for node in "${nodes[@]}"; do
        if ! run_on_node "$node" "$command" "$description"; then
            failed+=("$node")
        fi
    done
    
    if [ ${#failed[@]} -eq 0 ]; then
        log_success "$description completed on all nodes"
        return 0
    else
        log_error "$description failed on: ${failed[*]}"
        return 1
    fi
}

log "=== Phase 1: Prerequisites Setup ==="
log "Setting up Kubernetes prerequisites on all nodes"

# Step 1: Disable swap
log ""
log "${YELLOW}Step 1: Disabling swap on all nodes...${NC}"
disable_swap_cmd='sudo swapoff -a && sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab'
if ! run_on_all_nodes "$disable_swap_cmd" "Disabling swap"; then
    log_warning "Swap disable failed on some nodes"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 2: Install containerd
log ""
log "${YELLOW}Step 2: Installing containerd and dependencies...${NC}"
install_containerd_script='
# Create temp directory
sudo mkdir -p /tmp/k8s-install
cd /tmp/k8s-install

# Download containerd
echo "Downloading containerd..."
sudo wget -q https://github.com/containerd/containerd/releases/download/v1.7.8/containerd-1.7.8-linux-amd64.tar.gz

# Extract and install containerd
echo "Installing containerd..."
sudo tar -C /usr/local -xzf containerd-1.7.8-linux-amd64.tar.gz

# Download runc
echo "Downloading runc..."
sudo wget -q https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# Download CNI plugins
echo "Downloading CNI plugins..."
sudo wget -q https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v1.3.0.tgz

echo "Containerd installation completed"
'

if ! run_on_all_nodes "$install_containerd_script" "Installing containerd"; then
    log_error "Containerd installation failed. Exiting."
    exit 1
fi

# Step 3: Configure containerd
log ""
log "${YELLOW}Step 3: Configuring containerd...${NC}"
configure_containerd_script='
# Create containerd config directory
sudo mkdir -p /etc/containerd

# Generate default config
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable SystemdCgroup
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# Create systemd service file
sudo tee /etc/systemd/system/containerd.service > /dev/null << "EOF"
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

echo "Containerd configured and started"
'

if ! run_on_all_nodes "$configure_containerd_script" "Configuring containerd"; then
    log_error "Containerd configuration failed. Exiting."
    exit 1
fi

# Step 4: Install crictl
log ""
log "${YELLOW}Step 4: Installing crictl...${NC}"
install_crictl_script='
# Create temp directory and download crictl
sudo mkdir -p /tmp/k8s-install
cd /tmp/k8s-install
echo "Downloading crictl..."
sudo wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz
echo "Installing crictl..."
sudo tar -C /usr/local/bin -xzf crictl-v1.28.0-linux-amd64.tar.gz

# Configure crictl
sudo tee /etc/crictl.yaml > /dev/null << "EOF"
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 2
debug: false
pull-image-on-create: false
EOF

# Add /usr/local/bin to PATH if not already there
if ! grep -q "/usr/local/bin" /home/vagrant/.bashrc; then
    echo "export PATH=/usr/local/bin:/usr/local/sbin:\$PATH" >> /home/vagrant/.bashrc
fi

echo "crictl installed and configured"
'

if ! run_on_all_nodes "$install_crictl_script" "Installing crictl"; then
    log_error "crictl installation failed. Exiting."
    exit 1
fi

# Step 5: Configure kernel modules
log ""
log "${YELLOW}Step 5: Configuring kernel modules and sysctl...${NC}"
configure_kernel_script='
# Configure kernel modules
sudo tee /etc/modules-load.d/containerd.conf > /dev/null << "EOF"
overlay
br_netfilter
EOF

# Load modules immediately
sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl parameters
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf > /dev/null << "EOF"
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl settings
sudo sysctl --system > /dev/null

echo "Kernel configuration completed"
'

if ! run_on_all_nodes "$configure_kernel_script" "Configuring kernel"; then
    log_error "Kernel configuration failed. Exiting."
    exit 1
fi

# Step 6: Verify installation
log ""
log "${YELLOW}Step 6: Verifying installation...${NC}"
verify_script='
echo "=== Verification Results ==="
echo "Node: $(hostname)"
echo ""
echo "Containerd version:"
/usr/local/bin/containerd --version
echo ""
echo "Runc version:"
/usr/local/sbin/runc --version | head -1
echo ""
echo "crictl version:"
/usr/local/bin/crictl --version
echo ""
echo "Containerd service status:"
sudo systemctl is-active containerd
echo ""
echo "CNI plugins installed:"
ls /opt/cni/bin/ | wc -l
echo "plugins available"
echo ""
'

log "Running verification on all nodes..."
nodes=("master-1" "master-2" "worker-1" "worker-2")
for node in "${nodes[@]}"; do
    log "${YELLOW}--- Verification results for $node ---${NC}"
    if [[ "$node" == "master-1" ]]; then
        eval "$verify_script"
    else
        ssh -o StrictHostKeyChecking=no vagrant@$node "$verify_script"
    fi
    echo
done

# Create completion marker
echo "Phase 1 completed: $(date)" > /home/vagrant/phase1_completed.txt

log ""
log_success "🎉 Phase 1 (Prerequisites) completed successfully!"
log ""
log "${CYAN}All nodes now have:${NC}"
log_success "  ✓ containerd v1.7.8 installed and running"
log_success "  ✓ runc v1.1.9 installed"
log_success "  ✓ crictl v1.28.0 installed"
log_success "  ✓ CNI plugins installed"
log_success "  ✓ Kernel modules configured"
log_success "  ✓ Swap disabled"
log ""
log "${YELLOW}Next step: ./phase2-certificates.sh${NC}"
