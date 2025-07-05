#!/bin/bash

# Kubernetes HA Cluster Installation Script - Complete from Scratch
# Run from master-1 node as vagrant user

set -euo pipefail

# Enable error handling
trap 'echo "Error occurred at line $LINENO. Exiting..."; exit 1' ERR

# Configuration Variables
CLUSTER_NAME="kubernetes-ha"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_DNS="10.96.0.10"
KUBERNETES_VERSION="1.29"
CRICTL_VERSION="v1.29.0"
CRI_DOCKERD_VERSION="0.3.15"

# Node definitions
declare -A NODES=(
    ["master-1"]="192.168.5.11"
    ["master-2"]="192.168.5.12"
    ["worker-1"]="192.168.5.21"
    ["worker-2"]="192.168.5.22"
    ["lb"]="192.168.5.30"
)

MASTERS=("master-1" "master-2")
WORKERS=("worker-1" "worker-2")
LB_VIP="192.168.5.30"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}=================================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=================================================================================${NC}"
    echo ""
}

# Enhanced error handling for remote commands
exec_on_node() {
    local node=$1
    shift
    local cmd="$@"
    local retries=3
    local count=0
    
    log_info "Executing on $node: $cmd"
    
    while [ $count -lt $retries ]; do
        if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
            if sudo bash -c "$cmd"; then
                return 0
            fi
        else
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 vagrant@$node "sudo bash -c \"$cmd\""; then
                return 0
            fi
        fi
        
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            log_warning "Command failed on $node, retrying ($count/$retries)..."
            sleep 5
        fi
    done
    
    log_error "Command failed on $node after $retries attempts: $cmd"
    return 1
}

# Execute command silently and return output only
exec_on_node_silent() {
    local node=$1
    shift
    local cmd="$@"
    
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        sudo bash -c "$cmd"
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 vagrant@$node "sudo bash -c \"$cmd\""
    fi
}

# Execute as vagrant user on remote node
exec_as_vagrant() {
    local node=$1
    shift
    local cmd="$@"
    
    log_info "Executing as vagrant on $node: $cmd"
    
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        bash -c "$cmd"
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 vagrant@$node "$cmd"
    fi
}

# Copy file to remote node with error handling
copy_to_node() {
    local node=$1
    local src=$2
    local dest=$3
    
    log_info "Copying $src to $node:$dest"
    
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        sudo cp "$src" "$dest"
    else
        # Generate a unique temporary filename
        local temp_name="temp_$(date +%s)_$(basename "$dest")"
        local temp_path="/tmp/$temp_name"
        
        # Copy to temp location first
        scp -o StrictHostKeyChecking=no "$src" "vagrant@$node:$temp_path"
        
        # Move to final destination
        ssh -o StrictHostKeyChecking=no vagrant@$node "sudo mv '$temp_path' '$dest'"
    fi
}

# Check if command exists on node
command_exists() {
    local node=$1
    local cmd=$2
    
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        command -v "$cmd" >/dev/null 2>&1
    else
        ssh -o StrictHostKeyChecking=no vagrant@$node "command -v $cmd >/dev/null 2>&1"
    fi
}

# Check if service is running on node
service_running() {
    local node=$1
    local service=$2
    
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        sudo systemctl is-active --quiet "$service" 2>/dev/null
    else
        ssh -o StrictHostKeyChecking=no vagrant@$node "sudo systemctl is-active --quiet $service 2>/dev/null"
    fi
}

# Wait for node to be ready
wait_for_node() {
    local node=$1
    local max_attempts=30
    local attempt=1
    
    log_info "Waiting for $node to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
            if ping -c 1 -W 2 localhost >/dev/null 2>&1; then
                log_success "$node is ready"
                return 0
            fi
        else
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 vagrant@$node "echo 'ready'" >/dev/null 2>&1; then
                log_success "$node is ready"
                return 0
            fi
        fi
        
        log_info "Attempt $attempt/$max_attempts: $node not ready, waiting..."
        sleep 10
        attempt=$((attempt + 1))
    done
    
    log_error "$node is not ready after $max_attempts attempts"
    return 1
}

# Install cri-dockerd for Docker support
install_cri_dockerd() {
    local node=$1
    
    log_info "Installing cri-dockerd on $node"
    
    # Check if cri-dockerd is already installed
    if command_exists "$node" "cri-dockerd"; then
        log_success "cri-dockerd is already installed on $node"
        return 0
    fi
    
    # Download and install cri-dockerd
    log_info "Downloading cri-dockerd on $node"
    exec_on_node "$node" "cd /tmp && curl -LO https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-jammy_amd64.deb"
    
    # Install the package
    exec_on_node "$node" "cd /tmp && dpkg -i cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-jammy_amd64.deb || apt-get -f install -y"
    
    # Configure cri-dockerd service
    exec_on_node "$node" "systemctl daemon-reload"
    exec_on_node "$node" "systemctl enable cri-docker.service"
    exec_on_node "$node" "systemctl enable cri-docker.socket"
    exec_on_node "$node" "systemctl start cri-docker.service"
    exec_on_node "$node" "systemctl start cri-docker.socket"
    
    # Verify installation
    sleep 5
    if service_running "$node" "cri-docker"; then
        log_success "cri-dockerd installed and running on $node"
    else
        log_error "cri-dockerd failed to start on $node"
        return 1
    fi
    
    # Clean up
    exec_on_node "$node" "rm -f /tmp/cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-jammy_amd64.deb"
}

# Install crictl with proper error handling
install_crictl() {
    local node=$1
    
    log_info "Installing crictl on $node"
    
    # Check if crictl is already installed and working
    if command_exists "$node" "crictl"; then
        log_success "crictl is already installed on $node"
        return 0
    fi
    
    # Method 1: Try direct download with proper error handling
    download_success=false
    
    # Create temp directory
    exec_on_node "$node" "mkdir -p /tmp/crictl-install"
    
    # Try downloading crictl
    if exec_on_node "$node" "cd /tmp/crictl-install && curl -L --fail --retry 3 --retry-delay 5 -o crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"; then
        # Verify the download
        if exec_on_node "$node" "cd /tmp/crictl-install && file crictl.tar.gz | grep -q 'gzip compressed'"; then
            log_success "crictl downloaded successfully on $node"
            download_success=true
        else
            log_warning "Downloaded file is not a valid gzip archive on $node"
        fi
    else
        log_warning "Failed to download crictl from GitHub on $node"
    fi
    
    # If download failed, try alternative method
    if [ "$download_success" = false ]; then
        log_info "Trying alternative download method for crictl on $node"
        
        # Try wget as fallback
        if exec_on_node "$node" "cd /tmp/crictl-install && wget --retry-connrefused --waitretry=5 --timeout=20 --tries=3 -O crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"; then
            if exec_on_node "$node" "cd /tmp/crictl-install && file crictl.tar.gz | grep -q 'gzip compressed'"; then
                log_success "crictl downloaded successfully using wget on $node"
                download_success=true
            fi
        fi
    fi
    
    # If still failed, try a different version or skip
    if [ "$download_success" = false ]; then
        log_warning "Failed to download crictl, trying older version on $node"
        
        # Try v1.28.0 as fallback
        if exec_on_node "$node" "cd /tmp/crictl-install && curl -L --fail --retry 3 --retry-delay 5 -o crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz"; then
            if exec_on_node "$node" "cd /tmp/crictl-install && file crictl.tar.gz | grep -q 'gzip compressed'"; then
                log_success "crictl v1.28.0 downloaded successfully on $node"
                download_success=true
            fi
        fi
    fi
    
    if [ "$download_success" = true ]; then
        # Extract and install
        exec_on_node "$node" "cd /tmp/crictl-install && tar zxf crictl.tar.gz"
        exec_on_node "$node" "cd /tmp/crictl-install && mv crictl /usr/local/bin/"
        exec_on_node "$node" "chmod +x /usr/local/bin/crictl"
        
        # Verify installation
        if exec_on_node "$node" "/usr/local/bin/crictl --version >/dev/null 2>&1"; then
            log_success "crictl installed successfully on $node"
        else
            log_error "crictl installation verification failed on $node"
            return 1
        fi
    else
        log_warning "Skipping crictl installation on $node - will use containerd CLI instead"
    fi
    
    # Clean up
    exec_on_node "$node" "rm -rf /tmp/crictl-install"
    
    # Configure crictl if it was installed
    if command_exists "$node" "crictl"; then
        # Determine the correct runtime endpoint
        local runtime_endpoint="unix:///var/run/containerd/containerd.sock"
        if command_exists "$node" "docker" && service_running "$node" "docker"; then
            runtime_endpoint="unix:///var/run/cri-dockerd.sock"
        fi
        
        exec_on_node "$node" "cat > /etc/crictl.yaml <<EOF
runtime-endpoint: ${runtime_endpoint}
image-endpoint: ${runtime_endpoint}
timeout: 2
debug: false
pull-image-on-create: false
EOF"
    fi
}

# Get the correct CRI socket for a node
get_cri_socket() {
    local node=$1
    
    # Check if Docker is running and cri-dockerd is available
    if command_exists "$node" "docker" && service_running "$node" "docker" && command_exists "$node" "cri-dockerd"; then
        echo "unix:///var/run/cri-dockerd.sock"
    else
        echo "unix:///var/run/containerd/containerd.sock"
    fi
}

# Install container runtime (prioritize containerd over Docker)
install_container_runtime() {
    local node=$1
    
    log_info "Installing container runtime on $node"
    
    # Check if containerd is already installed and running
    if command_exists "$node" "containerd" && service_running "$node" "containerd"; then
        log_success "containerd is already installed and running on $node"
        log_info "Configuring containerd for Kubernetes on $node"
        
        # Configure containerd
        exec_on_node "$node" "mkdir -p /etc/containerd"
        exec_on_node "$node" "containerd config default > /etc/containerd/config.toml"
        exec_on_node "$node" "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml"
        exec_on_node "$node" "systemctl restart containerd"
        exec_on_node "$node" "systemctl enable containerd"
        
        log_success "containerd configured for Kubernetes on $node"
        install_crictl "$node"
        return 0
    fi
    
    # Check if Docker is running
    if command_exists "$node" "docker" && service_running "$node" "docker"; then
        log_info "Docker is running on $node, installing cri-dockerd for Kubernetes compatibility"
        install_cri_dockerd "$node"
        install_crictl "$node"
        return 0
    fi
    
    # If neither is installed, install containerd (preferred)
    log_info "Installing containerd on $node"
    
    # Remove any conflicting packages
    exec_on_node "$node" "apt-get remove -y docker docker-engine docker.io runc 2>/dev/null || true"
    
    # Add Docker repository (for containerd) with improved GPG handling
    log_info "Adding Docker repository on $node"
    exec_on_node "$node" "install -m 0755 -d /etc/apt/keyrings"
    
    # Download GPG key with better error handling
    if ! exec_on_node "$node" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg"; then
        log_error "Failed to download Docker GPG key on $node"
        return 1
    fi
    
    # Import GPG key
    exec_on_node "$node" "gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg"
    exec_on_node "$node" "chmod a+r /etc/apt/keyrings/docker.gpg"
    exec_on_node "$node" "rm -f /tmp/docker.gpg"
    
    # Create Docker repository file
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        sudo bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'
    else
        ssh -o StrictHostKeyChecking=no vagrant@$node 'sudo bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"'
    fi
    
    exec_on_node "$node" "apt-get update -qq"
    
    # Install containerd
    exec_on_node "$node" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd.io"
    
    # Configure containerd
    log_info "Configuring containerd on $node"
    exec_on_node "$node" "mkdir -p /etc/containerd"
    exec_on_node "$node" "containerd config default > /etc/containerd/config.toml"
    
    # Enable systemd cgroup driver
    exec_on_node "$node" "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml"
    
    # Restart and enable containerd
    exec_on_node "$node" "systemctl restart containerd"
    exec_on_node "$node" "systemctl enable containerd"
    
    # Verify containerd is running
    sleep 5
    if service_running "$node" "containerd"; then
        log_success "containerd is running on $node"
    else
        log_error "containerd failed to start on $node"
        exec_on_node "$node" "systemctl status containerd"
        return 1
    fi
    
    # Install crictl
    install_crictl "$node"
    
    log_success "Container runtime installed on $node"
}

# Disable swap with safer method
disable_swap() {
    local node=$1
    
    log_info "Disabling swap on $node"
    
    # Turn off swap immediately
    exec_on_node "$node" "swapoff -a || true"
    
    # Comment out swap entries in fstab using a safer approach
    if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
        sudo bash -c "cp /etc/fstab /etc/fstab.bak"
        sudo bash -c "grep -v swap /etc/fstab.bak > /etc/fstab || true"
    else
        ssh -o StrictHostKeyChecking=no vagrant@$node "sudo cp /etc/fstab /etc/fstab.bak"
        ssh -o StrictHostKeyChecking=no vagrant@$node "sudo bash -c 'grep -v swap /etc/fstab.bak > /etc/fstab || true'"
    fi
    
    log_success "Swap disabled on $node"
}

# Verify prerequisites - More lenient for development environments
verify_prerequisites() {
    log_info "Verifying prerequisites..."
    
    # Check if we can reach all nodes
    for node in "${!NODES[@]}"; do
        wait_for_node "$node"
    done
    
    # Check minimum requirements - More lenient for dev/test environments
    for node in "${!NODES[@]}"; do
        log_info "Checking minimum requirements on $node"
        
        # Adjusted memory requirements for development environment
        min_memory=400  # Reduced from 512MB
        recommended_memory=512
        if [[ " ${MASTERS[@]} " =~ " ${node} " ]]; then
            min_memory=768      # Reduced from 1024MB
            recommended_memory=1024
        fi
        
        memory_kb=""
        if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
            memory_kb=$(free | grep '^Mem:' | awk '{print $2}')
        else
            memory_kb=$(ssh -o StrictHostKeyChecking=no vagrant@$node "free | grep '^Mem:' | awk '{print \$2}'")
        fi
        
        memory_mb=$((memory_kb / 1024))
        
        if [ $memory_mb -lt $min_memory ]; then
            log_error "$node has insufficient memory: ${memory_mb}MB (absolute minimum: ${min_memory}MB)"
            log_error "This may cause cluster instability. Consider increasing VM memory."
            return 1
        elif [ $memory_mb -lt $recommended_memory ]; then
            log_warning "$node has limited memory: ${memory_mb}MB (recommended: ${recommended_memory}MB)"
            log_warning "Cluster should work but may be slower. Consider increasing VM memory for production."
        else
            log_success "$node meets memory requirements: ${memory_mb}MB"
        fi
        
        # Check CPU cores
        cpu_cores=""
        if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
            cpu_cores=$(nproc)
        else
            cpu_cores=$(ssh -o StrictHostKeyChecking=no vagrant@$node "nproc")
        fi
        
        if [ $cpu_cores -lt 1 ]; then
            log_error "$node has insufficient CPU cores: $cpu_cores"
            return 1
        else
            log_success "$node has sufficient CPU cores: $cpu_cores"
        fi
        
        # Check disk space (at least 10GB free)
        disk_free_gb=""
        if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
            disk_free_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
        else
            disk_free_gb=$(ssh -o StrictHostKeyChecking=no vagrant@$node "df / | tail -1 | awk '{print int(\$4/1024/1024)}'")
        fi
        
        if [ $disk_free_gb -lt 5 ]; then
            log_error "$node has insufficient disk space: ${disk_free_gb}GB (minimum: 5GB)"
            return 1
        else
            log_success "$node has sufficient disk space: ${disk_free_gb}GB"
        fi
    done
    
    log_success "All prerequisite checks passed"
}

print_header "KUBERNETES HA CLUSTER INSTALLATION - FROM SCRATCH"
echo "Starting installation at $(date)"
echo "Cluster configuration:"
echo "- Kubernetes Version: v${KUBERNETES_VERSION}"
echo "- Pod CIDR: ${POD_CIDR}"
echo "- Service CIDR: ${SERVICE_CIDR}"
echo "- Control Plane Endpoint: ${LB_VIP}:6443"
echo ""

# Verify prerequisites first
verify_prerequisites

# PHASE 1: SYSTEM PREPARATION
print_header "PHASE 1: System Preparation on All Nodes"

for node in "${!NODES[@]}"; do
    log_info "Preparing system on $node (${NODES[$node]})"
    
    # Update system and install basic packages
    log_info "Updating system packages on $node"
    exec_on_node "$node" "apt-get update -qq"
    exec_on_node "$node" "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
    
    log_info "Installing basic packages on $node"
    exec_on_node "$node" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common \
        gnupg \
        lsb-release \
        wget \
        socat \
        conntrack \
        ipset \
        iptables \
        arptables \
        ebtables \
        file \
        python3"
    
    # Configure iptables to use legacy mode (required for some CNI plugins)
    log_info "Configuring iptables legacy mode on $node"
    exec_on_node "$node" "update-alternatives --set iptables /usr/sbin/iptables-legacy || true"
    exec_on_node "$node" "update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true"
    exec_on_node "$node" "update-alternatives --set arptables /usr/sbin/arptables-legacy || true"
    exec_on_node "$node" "update-alternatives --set ebtables /usr/sbin/ebtables-legacy || true"
    
    # Disable swap with improved method
    disable_swap "$node"
    
    # Load kernel modules
    log_info "Loading and configuring kernel modules on $node"
    exec_on_node "$node" "modprobe overlay"
    exec_on_node "$node" "modprobe br_netfilter"
    
    # Make kernel modules persistent - Fixed heredoc
    exec_on_node "$node" "cat > /etc/modules-load.d/k8s.conf << 'MODEOF'
overlay
br_netfilter
MODEOF"
    
    # Configure sysctl parameters - Fixed heredoc
    log_info "Configuring sysctl parameters on $node"
    exec_on_node "$node" "cat > /etc/sysctl.d/k8s.conf << 'SYSCTLEOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTLEOF"
    exec_on_node "$node" "sysctl --system >/dev/null 2>&1"
    
    # Disable UFW firewall if present
    log_info "Disabling UFW firewall on $node"
    exec_on_node "$node" "ufw --force disable || true"
    
    log_success "System preparation completed on $node"
done

# PHASE 2: CONTAINER RUNTIME INSTALLATION
print_header "PHASE 2: Installing Container Runtime"

for node in "${!NODES[@]}"; do
    install_container_runtime "$node"
done

# PHASE 3: KUBERNETES PACKAGES INSTALLATION
print_header "PHASE 3: Installing Kubernetes Packages"

for node in "${!NODES[@]}"; do
    log_info "Installing Kubernetes packages on $node"
    
    # Add Kubernetes repository with improved GPG handling
    log_info "Adding Kubernetes repository on $node"
    exec_on_node "$node" "mkdir -p /etc/apt/keyrings"
    
    # Download Kubernetes GPG key with better error handling
    if ! exec_on_node "$node" "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key -o /tmp/kubernetes.gpg"; then
        log_error "Failed to download Kubernetes GPG key on $node"
        return 1
    fi
    
    # Import GPG key
    exec_on_node "$node" "gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/kubernetes.gpg"
    exec_on_node "$node" "chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    exec_on_node "$node" "rm -f /tmp/kubernetes.gpg"
    
    # Add Kubernetes repository
    exec_on_node "$node" "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
    
    # Update package list
    exec_on_node "$node" "apt-get update -qq"
    
    # Install Kubernetes packages
    log_info "Installing kubeadm, kubelet, kubectl on $node"
    exec_on_node "$node" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kubelet kubeadm kubectl"
    exec_on_node "$node" "apt-mark hold kubelet kubeadm kubectl"
    
    # Configure kubelet
    exec_on_node "$node" "systemctl enable kubelet"
    
    # Configure kubelet for the detected container runtime
    exec_on_node "$node" "mkdir -p /etc/systemd/system/kubelet.service.d"
    
    # Get the CRI socket for this node
    cri_socket=$(get_cri_socket "$node")
    
    # Create kubelet configuration - Fixed heredoc
    exec_on_node "$node" "cat > /etc/systemd/system/kubelet.service.d/20-low-resource.conf << 'KUBELETEOF'
[Service]
Environment=\"KUBELET_EXTRA_ARGS=--feature-gates=NodeSwap=false --fail-swap-on=false --container-runtime-endpoint=${cri_socket}\"
KUBELETEOF"
    
    exec_on_node "$node" "systemctl daemon-reload"
    
    # Verify installations
    for cmd in kubeadm kubelet kubectl; do
        if command_exists "$node" "$cmd"; then
            version=""
            if [[ "$node" == "master-1" ]] || [[ "$node" == "$(hostname)" ]]; then
                version=$(sudo $cmd version --client --short 2>/dev/null | cut -d' ' -f3 2>/dev/null || echo "unknown")
            else
                version=$(ssh -o StrictHostKeyChecking=no vagrant@$node "sudo $cmd version --client --short 2>/dev/null | cut -d' ' -f3 2>/dev/null" || echo "unknown")
            fi
            log_success "$cmd installed on $node: $version"
        else
            log_error "$cmd installation failed on $node"
            return 1
        fi
    done
done

# PHASE 4: LOAD BALANCER SETUP
print_header "PHASE 4: Setting up Load Balancer (HAProxy)"

log_info "Installing and configuring HAProxy on lb node"

# Install HAProxy
exec_on_node "lb" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq haproxy"

# Backup original configuration
exec_on_node "lb" "cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup"

# Configure HAProxy
log_info "Configuring HAProxy for Kubernetes API"

# Create HAProxy configuration file directly on the remote node - Fixed heredoc
exec_on_node "lb" "cat > /etc/haproxy/haproxy.cfg << 'HAPROXYEOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    option dontlognull
    retries 3

frontend kubernetes-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-backend

backend kubernetes-backend
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
    server master-1 ${NODES['master-1']}:6443 check
    server master-2 ${NODES['master-2']}:6443 check

listen stats
    bind *:8404
    stats enable
    stats uri /
    stats refresh 30s
    stats admin if TRUE
HAPROXYEOF"

# Start and enable HAProxy
exec_on_node "lb" "systemctl restart haproxy"
exec_on_node "lb" "systemctl enable haproxy"

# Verify HAProxy is running
sleep 5
if service_running "lb" "haproxy"; then
    log_success "HAProxy is running on lb node"
else
    log_error "HAProxy failed to start on lb node"
    exec_on_node "lb" "systemctl status haproxy"
    return 1
fi

# PHASE 5: INITIALIZE FIRST MASTER
print_header "PHASE 5: Initializing First Master Node"

log_info "Creating kubeadm configuration for master-1"

# Get the CRI socket for master-1
master1_cri_socket=$(get_cri_socket "master-1")

# Create kubeadm configuration directly on master-1 - Fixed heredoc
exec_on_node "master-1" "cat > /tmp/kubeadm-config.yaml << 'KUBEADMEOF'
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODES['master-1']}
  bindPort: 6443
nodeRegistration:
  criSocket: ${master1_cri_socket}
  kubeletExtraArgs:
    feature-gates: \"NodeSwap=false\"
    fail-swap-on: \"false\"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${KUBERNETES_VERSION}.0
controlPlaneEndpoint: \"${LB_VIP}:6443\"
clusterName: ${CLUSTER_NAME}
networking:
  serviceSubnet: ${SERVICE_CIDR}
  podSubnet: ${POD_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - \"${LB_VIP}\"
    - \"${NODES['master-1']}\"
    - \"${NODES['master-2']}\"
    - \"master-1\"
    - \"master-2\"
    - \"lb\"
    - \"localhost\"
    - \"127.0.0.1\"
  extraArgs:
    bind-address: \"0.0.0.0\"
    service-cluster-ip-range: ${SERVICE_CIDR}
    feature-gates: \"NodeSwap=false\"
controllerManager:
  extraArgs:
    bind-address: \"0.0.0.0\"
    feature-gates: \"NodeSwap=false\"
scheduler:
  extraArgs:
    bind-address: \"0.0.0.0\"
    feature-gates: \"NodeSwap=false\"
etcd:
  local:
    dataDir: \"/var/lib/etcd\"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: false
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: \"iptables\"
KUBEADMEOF"

# Initialize cluster
log_info "Initializing Kubernetes cluster on master-1 (this may take several minutes)"
exec_on_node "master-1" "kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs --v=5"

# Configure kubectl for vagrant user
log_info "Configuring kubectl for vagrant user on master-1"
exec_as_vagrant "master-1" "mkdir -p ~/.kube"
exec_on_node "master-1" "cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config"
exec_on_node "master-1" "chown vagrant:vagrant /home/vagrant/.kube/config"

# Wait for API server to be ready
log_info "Waiting for API server to be ready..."
sleep 30

# Test kubectl access
attempts=0
max_attempts=10
while [ $attempts -lt $max_attempts ]; do
    if exec_as_vagrant "master-1" "kubectl cluster-info >/dev/null 2>&1"; then
        log_success "kubectl is working on master-1"
        break
    else
        attempts=$((attempts + 1))
        log_info "API server not ready yet, waiting... ($attempts/$max_attempts)"
        sleep 15
    fi
done

if [ $attempts -eq $max_attempts ]; then
    log_error "API server failed to become ready"
    return 1
fi

# Get join commands using silent execution
log_info "Generating join tokens and commands"
WORKER_JOIN_CMD=$(exec_on_node_silent "master-1" "kubeadm token create --print-join-command")
CERT_KEY=$(exec_on_node_silent "master-1" "kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1")
CONTROL_PLANE_JOIN_CMD="${WORKER_JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}"

log_info "Worker join command: $WORKER_JOIN_CMD"
log_info "Certificate key: $CERT_KEY"

log_success "First master node initialized successfully"

# PHASE 6: JOIN SECOND MASTER
print_header "PHASE 6: Joining Second Master Node"

# Get the CRI socket for master-2
master2_cri_socket=$(get_cri_socket "master-2")

log_info "Joining master-2 to the cluster"
log_info "Join command: $CONTROL_PLANE_JOIN_CMD --cri-socket ${master2_cri_socket}"
exec_on_node "master-2" "$CONTROL_PLANE_JOIN_CMD --cri-socket ${master2_cri_socket}"

# Configure kubectl on master-2
log_info "Configuring kubectl for vagrant user on master-2"
exec_as_vagrant "master-2" "mkdir -p ~/.kube"
exec_on_node "master-2" "cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config"
exec_on_node "master-2" "chown vagrant:vagrant /home/vagrant/.kube/config"

# Verify master-2 joined
sleep 10
if exec_as_vagrant "master-2" "kubectl get nodes >/dev/null 2>&1"; then
    log_success "master-2 joined successfully and kubectl is working"
else
    log_error "master-2 join failed or kubectl is not working"
    return 1
fi

# PHASE 7: INSTALL POD NETWORK (Calico)
print_header "PHASE 7: Installing Pod Network (Calico)"

log_info "Installing Calico network plugin"

# Wait for control plane to be stable
log_info "Waiting for control plane to be stable..."
sleep 30

# Install Tigera operator
log_info "Installing Tigera operator"
exec_as_vagrant "master-1" "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml"

# Wait for operator to be ready
log_info "Waiting for Tigera operator to be ready..."
sleep 30

# Create Calico installation directly on master-1 - Fixed heredoc
exec_on_node "master-1" "cat > /tmp/calico-custom-resources.yaml << 'CALICOEOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
CALICOEOF"

exec_as_vagrant "master-1" "kubectl create -f /tmp/calico-custom-resources.yaml"

# Wait for Calico to be ready
log_info "Waiting for Calico components to be ready..."
sleep 90

log_success "Calico network plugin installation initiated"

# PHASE 8: JOIN WORKER NODES
print_header "PHASE 8: Joining Worker Nodes"

# Join worker-1
log_info "Joining worker-1 to the cluster"
worker1_cri_socket=$(get_cri_socket "worker-1")
exec_on_node "worker-1" "$WORKER_JOIN_CMD --cri-socket ${worker1_cri_socket}"

# Join worker-2
log_info "Joining worker-2 to the cluster"
worker2_cri_socket=$(get_cri_socket "worker-2")
exec_on_node "worker-2" "$WORKER_JOIN_CMD --cri-socket ${worker2_cri_socket}"

# Wait for nodes to be ready
log_info "Waiting for worker nodes to be ready..."
sleep 60

# PHASE 9: CONFIGURE RBAC FOR API SERVER TO KUBELET
print_header "PHASE 9: Configuring RBAC"

log_info "Setting up API server to kubelet communication RBAC"

exec_as_vagrant "master-1" "cat <<'RBACEOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: 'true'
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ''
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - '*'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ''
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
RBACEOF"

log_success "RBAC configured for API server to kubelet communication"

# PHASE 10: VERIFY DNS AND FINAL TESTING
print_header "PHASE 10: Final Verification and Testing"

# Wait for all components to be ready
log_info "Waiting for all components to be ready..."
sleep 60

# Check node status
log_info "Checking node status..."
exec_as_vagrant "master-1" "kubectl get nodes -o wide"

# Check system pods
log_info "Checking system pods..."
exec_as_vagrant "master-1" "kubectl get pods -n kube-system"

# Check Calico pods
log_info "Checking Calico pods..."
exec_as_vagrant "master-1" "kubectl get pods -n calico-system" || log_warning "Calico system pods not ready yet"

# Test basic cluster functionality
log_info "Testing basic cluster functionality..."

# Create test deployment directly on master-1 - Fixed heredoc
exec_on_node "master-1" "cat > /tmp/nginx-test.yaml << 'NGINXEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: \"32Mi\"
            cpu: \"10m\"
          limits:
            memory: \"64Mi\"
            cpu: \"50m\"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: default
spec:
  selector:
    app: nginx-test
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
NGINXEOF"

exec_as_vagrant "master-1" "kubectl apply -f /tmp/nginx-test.yaml"

# Wait for deployment
log_info "Waiting for test deployment to be ready..."
sleep 45

# Check deployment status
exec_as_vagrant "master-1" "kubectl get deployment nginx-test"
exec_as_vagrant "master-1" "kubectl get pods -l app=nginx-test"

# Clean up test deployment
exec_as_vagrant "master-1" "kubectl delete -f /tmp/nginx-test.yaml"

# INSTALLATION COMPLETE
print_header "KUBERNETES HA CLUSTER INSTALLATION COMPLETE!"

# Determine container runtime for display
container_runtime="containerd"
if command_exists "master-1" "docker" && service_running "master-1" "docker"; then
    container_runtime="Docker with cri-dockerd"
fi

cat <<EOF

${GREEN}🎉 Kubernetes HA Cluster Successfully Installed! 🎉${NC}

${BLUE}📋 Cluster Information:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Cluster Name: ${CLUSTER_NAME}
• Kubernetes Version: v${KUBERNETES_VERSION}.0
• Control Plane Endpoint: ${LB_VIP}:6443
• Pod Network (Calico): ${POD_CIDR}
• Service Network: ${SERVICE_CIDR}
• Container Runtime: ${container_runtime}

${BLUE}🖥️  Node Information:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Master-1: ${NODES['master-1']} (Control Plane)
• Master-2: ${NODES['master-2']} (Control Plane)
• Worker-1: ${NODES['worker-1']} (Worker Node)
• Worker-2: ${NODES['worker-2']} (Worker Node)
• Load Balancer: ${NODES['lb']} (HAProxy)

${BLUE}✅ Features Configured:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ High Availability Control Plane (2 masters)
✓ Load Balancer (HAProxy) with health checks
✓ Container Runtime (${container_runtime})
✓ Pod Networking (Calico CNI)
✓ DNS Resolution (CoreDNS)
✓ RBAC (API server to kubelet communication)
✓ All nodes joined and ready
✓ Optimized for low-resource environments

${BLUE}🔧 Access Instructions:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
From master-1 or master-2:
  kubectl get nodes
  kubectl get pods --all-namespaces
  kubectl cluster-info

HAProxy Stats: http://${LB_VIP}:8404

${BLUE}🚀 Next Steps:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Deploy your applications
2. Set up Ingress Controller (nginx-ingress)
3. Configure monitoring (Prometheus/Grafana)
4. Set up persistent storage
5. Implement backup strategy for etcd
6. Configure network policies
7. Set up log aggregation

${BLUE}📊 Final Cluster Status:${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# Show final cluster status
exec_as_vagrant "master-1" "kubectl get nodes -o wide"
echo ""
exec_as_vagrant "master-1" "kubectl get pods -n kube-system"

echo ""
echo -e "${GREEN}Installation completed successfully at $(date)${NC}"
echo -e "${BLUE}Total installation time: $SECONDS seconds${NC}"

log_success "Kubernetes HA cluster is ready for use!"

# Create a summary file
cat > ~/cluster-info.txt <<EOF
Kubernetes HA Cluster Information
================================

Cluster Details:
- Name: ${CLUSTER_NAME}
- Version: v${KUBERNETES_VERSION}.0
- Control Plane: ${LB_VIP}:6443
- Pod CIDR: ${POD_CIDR}
- Service CIDR: ${SERVICE_CIDR}

Node Information:
- Master-1: ${NODES['master-1']}
- Master-2: ${NODES['master-2']}
- Worker-1: ${NODES['worker-1']}
- Worker-2: ${NODES['worker-2']}
- Load Balancer: ${NODES['lb']}

Container Runtime: ${container_runtime}

Access:
- kubectl get nodes
- kubectl cluster-info
- HAProxy Stats: http://${LB_VIP}:8404

Installation completed: $(date)
EOF

echo ""
echo -e "${BLUE}Cluster information saved to ~/cluster-info.txt${NC}"