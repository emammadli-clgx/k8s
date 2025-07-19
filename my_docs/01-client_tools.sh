#!/bin/bash

# install-kubectl.sh
# Purpose: Install kubectl on master nodes
# Run on: master-1

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
KUBECTL_VERSION="v1.29.0"
KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
KUBECTL_SHA256_URL="https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Function to install kubectl on a node
install_kubectl_on_node() {
    local node=$1
    
    log "Installing kubectl ${KUBECTL_VERSION} on ${node}..."
    
    if [ "$node" == "master-1" ] || [ "$node" == "localhost" ] || [ "$node" == "$(hostname)" ]; then
        # Install locally
        log "Downloading kubectl..."
        wget -q --show-progress --https-only --timestamping "${KUBECTL_URL}" -O /tmp/kubectl
        
        log "Downloading kubectl checksum..."
        wget -q "${KUBECTL_SHA256_URL}" -O /tmp/kubectl.sha256
        
        log "Verifying kubectl binary..."
        echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check --status || {
            error "kubectl binary verification failed!"
            return 1
        }
        
        log "Installing kubectl..."
        chmod +x /tmp/kubectl
        sudo mv /tmp/kubectl /usr/local/bin/kubectl
        
        # Cleanup
        rm -f /tmp/kubectl.sha256
    else
        # Install on remote node
        log "Copying installation commands to ${node}..."
        ssh -o StrictHostKeyChecking=no vagrant@${node} bash << 'ENDSSH'
set -euo pipefail

echo "Downloading kubectl on remote node..."
wget -q --show-progress --https-only --timestamping "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl" -O /tmp/kubectl

echo "Downloading kubectl checksum..."
wget -q "https://dl.k8s.io/v1.29.0/bin/linux/amd64/kubectl.sha256" -O /tmp/kubectl.sha256

echo "Verifying kubectl binary..."
echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check --status || {
    echo "kubectl binary verification failed!"
    exit 1
}

echo "Installing kubectl..."
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl

# Cleanup
rm -f /tmp/kubectl.sha256

# Verify installation
kubectl version --client --short 2>/dev/null || echo "kubectl version command failed"
ENDSSH
    fi
    
    log "kubectl installation completed on ${node}"
}

# Main execution
main() {
    log "Starting kubectl installation process..."
    
    # Check if running on master-1 (flexible hostname check)
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        error "Current hostname: $current_hostname"
        exit 1
    fi
    
    # Test SSH connectivity first
    log "Testing SSH connectivity to master-2..."
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 vagrant@master-2 echo "SSH OK" &> /dev/null; then
        error "Cannot SSH to master-2. Please check your Vagrant setup."
        exit 1
    fi
    
    # Install on both master nodes
    for node in master-1 master-2; do
        if ! install_kubectl_on_node "$node"; then
            error "Failed to install kubectl on ${node}"
            exit 1
        fi
    done
    
    log "kubectl installation completed on all master nodes"
    
    # Display version on local node
    log "Local kubectl version:"
    kubectl version --client
}

# Run main function
main