#!/bin/bash

# bootstrap-k8s-control-plane-final.sh
# Purpose: Bootstrap Kubernetes control plane components
# Run on: master-1 and master-2

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
K8S_VERSION="1.28.4"
K8S_CONFIG_DIR="/etc/kubernetes/config"
K8S_LIB_DIR="/var/lib/kubernetes"
NETWORK_INTERFACE="enp0s8"

# Master node IPs
MASTER1_IP="192.168.5.11"
MASTER2_IP="192.168.5.12"

# Kubernetes download URLs
K8S_BASE_URL="https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64"
K8S_BINARIES=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "kubectl")

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" >&2
}

# Get current node information
get_node_info() {
    local hostname=$(hostname -s)
    local internal_ip
    
    if ! internal_ip=$(ip addr show ${NETWORK_INTERFACE} 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d / -f 1); then
        error "Failed to get IP address from interface ${NETWORK_INTERFACE}"
        exit 1
    fi
    
    if [[ -z "$internal_ip" ]]; then
        error "No IP address found on interface ${NETWORK_INTERFACE}"
        exit 1
    fi
    
    echo "${hostname}:${internal_ip}"
}

# Find and prepare required files using actual locations
find_and_prepare_files() {
    log "Finding and preparing required files..."
    
    local hostname=$(hostname -s)
    local missing_files=()
    
    # Copy service account certificates from distribution directory on master-1
    if [[ "$hostname" == "master-1" ]]; then
        if [[ -f "./certs/distribution/service-account.crt" ]]; then
            cp "./certs/distribution/service-account.crt" ~/
            info "✓ Copied service-account.crt from distribution directory"
        fi
        
        if [[ -f "./certs/distribution/service-account.key" ]]; then
            cp "./certs/distribution/service-account.key" ~/
            chmod 600 ~/service-account.key
            info "✓ Copied service-account.key from distribution directory"
        fi
    fi
    
    # Check all required files in home directory
    local required_files=(
        "ca.crt" "ca.key"
        "kube-apiserver.crt" "kube-apiserver.key"
        "service-account.crt" "service-account.key"
        "etcd-server.crt" "etcd-server.key"
        "encryption-config.yaml"
        "admin.kubeconfig"
        "kube-controller-manager.kubeconfig"
        "kube-scheduler.kubeconfig"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$HOME/$file" ]]; then
            info "✓ Found $file in home directory"
        else
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        error "Missing required files in home directory:"
        for file in "${missing_files[@]}"; do
            error "  - $file"
        done
        exit 1
    fi
    
    log "All required files found and ready"
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    # Check if running as non-root user
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root (needs sudo for specific commands)"
        exit 1
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error "This script requires sudo access"
        exit 1
    fi
    
    # Check network interface
    if ! ip addr show ${NETWORK_INTERFACE} > /dev/null 2>&1; then
        error "Network interface ${NETWORK_INTERFACE} not found"
        exit 1
    fi
    
    # Check etcd is running (prerequisite)
    if ! sudo systemctl is-active --quiet etcd; then
        error "etcd service is not running. Bootstrap etcd first."
        exit 1
    fi
    
    # Find and prepare files
    find_and_prepare_files
    
    log "Prerequisites verified"
}

# Create Kubernetes directories
create_k8s_directories() {
    log "Creating Kubernetes directories..."
    
    sudo mkdir -p ${K8S_CONFIG_DIR}
    sudo mkdir -p ${K8S_LIB_DIR}
    sudo mkdir -p /var/log/kubernetes
    
    # Set proper permissions
    sudo chmod 755 ${K8S_CONFIG_DIR}
    sudo chmod 755 ${K8S_LIB_DIR}
    sudo chmod 755 /var/log/kubernetes
    
    log "Kubernetes directories created"
}

# Download and install Kubernetes binaries
install_k8s_binaries() {
    log "Downloading and installing Kubernetes v${K8S_VERSION} binaries..."
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download Kubernetes binaries
    for binary in "${K8S_BINARIES[@]}"; do
        local url="${K8S_BASE_URL}/${binary}"
        info "Downloading $binary..."
        
        if ! wget -q --show-progress --https-only --timestamping "$url"; then
            error "Failed to download $binary from $url"
            exit 1
        fi
    done
    
    # Make binaries executable
    chmod +x "${K8S_BINARIES[@]}"
    
    # Install binaries
    sudo mv "${K8S_BINARIES[@]}" /usr/local/bin/
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    # Verify installation
    local kubectl_version=$(/usr/local/bin/kubectl version --client --short 2>/dev/null | head -1 || echo "kubectl client installed")
    log "Installed: $kubectl_version"
}

# Copy certificates and configs to Kubernetes directory
copy_certificates() {
    log "Copying certificates and configuration files..."
    
    # Copy files from home directory to Kubernetes lib directory
    local files_to_copy=(
        "ca.crt" "ca.key"
        "kube-apiserver.crt" "kube-apiserver.key"
        "service-account.crt" "service-account.key"
        "etcd-server.crt" "etcd-server.key"
        "encryption-config.yaml"
        "kube-controller-manager.kubeconfig"
        "kube-scheduler.kubeconfig"
    )
    
    for file in "${files_to_copy[@]}"; do
        if [[ -f "$HOME/$file" ]]; then
            sudo cp "$HOME/$file" ${K8S_LIB_DIR}/
            info "✓ Copied $file to ${K8S_LIB_DIR}/"
        else
            error "File not found: $HOME/$file"
            exit 1
        fi
    done
    
    # Set proper permissions
    sudo chmod 644 ${K8S_LIB_DIR}/*.crt
    sudo chmod 600 ${K8S_LIB_DIR}/*.key
    sudo chmod 644 ${K8S_LIB_DIR}/*.kubeconfig
    sudo chmod 644 ${K8S_LIB_DIR}/encryption-config.yaml
    sudo chown root:root ${K8S_LIB_DIR}/*
    
    log "Certificates and configs copied successfully"
}

# Create kube-apiserver systemd service
create_apiserver_service() {
    log "Creating kube-apiserver systemd service..."
    
    local node_info=$(get_node_info)
    local internal_ip=$(echo "$node_info" | cut -d: -f2)
    
    info "API Server will advertise on IP: $internal_ip"
    
    sudo tee /etc/systemd/system/kube-apiserver.service > /dev/null <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${internal_ip} \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/kubernetes/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=${K8S_LIB_DIR}/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=${K8S_LIB_DIR}/ca.crt \\
  --etcd-certfile=${K8S_LIB_DIR}/etcd-server.crt \\
  --etcd-keyfile=${K8S_LIB_DIR}/etcd-server.key \\
  --etcd-servers=https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=${K8S_LIB_DIR}/encryption-config.yaml \\
  --kubelet-certificate-authority=${K8S_LIB_DIR}/ca.crt \\
  --kubelet-client-certificate=${K8S_LIB_DIR}/kube-apiserver.crt \\
  --kubelet-client-key=${K8S_LIB_DIR}/kube-apiserver.key \\
  --runtime-config=api/all=true \\
  --service-account-key-file=${K8S_LIB_DIR}/service-account.crt \\
  --service-account-signing-key-file=${K8S_LIB_DIR}/service-account.key \\
  --service-account-issuer=https://${internal_ip}:6443 \\
  --service-cluster-ip-range=10.96.0.0/16 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=${K8S_LIB_DIR}/kube-apiserver.crt \\
  --tls-private-key-file=${K8S_LIB_DIR}/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    log "kube-apiserver service created"
}

# Create kube-controller-manager systemd service
create_controller_manager_service() {
    log "Creating kube-controller-manager systemd service..."
    
    sudo tee /etc/systemd/system/kube-controller-manager.service > /dev/null <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=192.168.5.0/24 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=${K8S_LIB_DIR}/ca.crt \\
  --cluster-signing-key-file=${K8S_LIB_DIR}/ca.key \\
  --kubeconfig=${K8S_LIB_DIR}/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=${K8S_LIB_DIR}/ca.crt \\
  --service-account-private-key-file=${K8S_LIB_DIR}/service-account.key \\
  --service-cluster-ip-range=10.96.0.0/16 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    log "kube-controller-manager service created"
}

# Create kube-scheduler systemd service
create_scheduler_service() {
    log "Creating kube-scheduler systemd service..."
    
    sudo tee /etc/systemd/system/kube-scheduler.service > /dev/null <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --kubeconfig=${K8S_LIB_DIR}/kube-scheduler.kubeconfig \\
  --leader-elect=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    log "kube-scheduler service created"
}

# Start Kubernetes services
start_k8s_services() {
    log "Starting Kubernetes control plane services..."
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    # Enable services
    sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
    
    # Start API server first
    log "Starting kube-apiserver..."
    sudo systemctl start kube-apiserver
    
    # Wait for API server to be ready
    sleep 10
    
    # Start controller manager
    log "Starting kube-controller-manager..."
    sudo systemctl start kube-controller-manager
    
    # Start scheduler
    log "Starting kube-scheduler..."
    sudo systemctl start kube-scheduler
    
    # Wait for services to start
    sleep 10
    
    log "Kubernetes control plane services started"
}

# Verify Kubernetes services
verify_k8s_services() {
    log "Verifying Kubernetes control plane services..."
    
    local services=("kube-apiserver" "kube-controller-manager" "kube-scheduler")
    local failed_services=()
    
    for service in "${services[@]}"; do
        if sudo systemctl is-active --quiet "$service"; then
            info "✓ $service is running"
        else
            error "✗ $service is not running"
            failed_services+=("$service")
        fi
    done
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        error "Some services failed to start:"
        for service in "${failed_services[@]}"; do
            echo ""
            echo "=== $service status ==="
            sudo systemctl status "$service" --no-pager -l
            echo ""
            echo "=== $service logs ==="
            sudo journalctl -u "$service" --no-pager -l -n 10
        done
        exit 1
    fi
    
    log "All Kubernetes services are running"
}

# Test API server connectivity
test_api_server() {
    log "Testing API server connectivity..."
    
    local max_attempts=20
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if /usr/local/bin/kubectl get componentstatuses --kubeconfig="$HOME/admin.kubeconfig" >/dev/null 2>&1; then
            log "API server is responding"
            break
        else
            if [ $attempt -eq $max_attempts ]; then
                error "API server is not responding after $max_attempts attempts"
                exit 1
            fi
            warning "API server not ready, attempt $attempt/$max_attempts, retrying..."
            sleep 5
            ((attempt++))
        fi
    done
    
    # Show component status
    info "Component status:"
    /usr/local/bin/kubectl get componentstatuses --kubeconfig="$HOME/admin.kubeconfig" || true
}

# Main execution
main() {
    local node_info=$(get_node_info)
    local hostname=$(echo "$node_info" | cut -d: -f1)
    local internal_ip=$(echo "$node_info" | cut -d: -f2)
    
    echo "=================================================="
    echo "Kubernetes Control Plane Bootstrap"
    echo "Node: $hostname"
    echo "IP: $internal_ip"
    echo "Kubernetes Version: v${K8S_VERSION}"
    echo "=================================================="
    
    # Verify prerequisites
    verify_prerequisites
    
    # Create directories
    create_k8s_directories
    
    # Install Kubernetes binaries
    install_k8s_binaries
    
    # Copy certificates and configs
    copy_certificates
    
    # Create systemd services
    create_apiserver_service
    create_controller_manager_service
    create_scheduler_service
    
    # Start services
    start_k8s_services
    
    # Verify services
    verify_k8s_services
    
    # Test API server
    test_api_server
    
    log "Kubernetes control plane bootstrap completed successfully!"
    
    echo ""
    echo "=================================================="
    echo "KUBERNETES CONTROL PLANE SUMMARY"
    echo "=================================================="
    echo "Node: $hostname"
    echo "API Server: https://$internal_ip:6443"
    echo "Cluster CIDR: 192.168.5.0/24"
    echo "Service CIDR: 10.96.0.0/16"
    echo "etcd endpoints: https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379"
    echo ""
    echo "Service Status:"
    echo "  - kube-apiserver: $(sudo systemctl is-active kube-apiserver)"
    echo "  - kube-controller-manager: $(sudo systemctl is-active kube-controller-manager)"
    echo "  - kube-scheduler: $(sudo systemctl is-active kube-scheduler)"
    echo "=================================================="
    
    warning "Run this script on all master nodes, then configure the load balancer"
}

# Run main function
main