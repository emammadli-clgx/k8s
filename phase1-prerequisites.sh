#!/bin/bash

#===============================================================================
# PHASE 1: PREREQUISITES SETUP
# Sets up the basic environment and installs required packages
#===============================================================================

# Exit on any error
set -euo pipefail

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

# Check if we're running as root
if [[ $EUID -eq 0 ]]; then
    log_error "This script should not be run as root"
    exit 1
fi

# Load common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
else
    log_error "config.env file not found. Please run setup.sh first."
    exit 1
fi

log "=== PHASE 1: Setting up Prerequisites ==="
log "Kubernetes Version: ${KUBERNETES_VERSION}"
log "etcd Version: ${ETCD_VERSION}"
log "Container Runtime: containerd"

# Create working directories
log "Creating working directories..."
mkdir -p "${CERT_DIR}" "${CONFIG_DIR}" || {
    log_error "Failed to create directories"
    exit 1
}

cd "${HOME}" || {
    log_error "Failed to change to home directory"
    exit 1
}

# Check if we're in a Vagrant environment
if [[ ! -f "/vagrant/Vagrantfile" ]] && [[ ! -d "/vagrant" ]]; then
    log_warn "Not running in Vagrant environment - some paths may differ"
fi

# Install required packages
log "Installing required packages..."
if ! sudo apt-get update -qq; then
    log_error "Failed to update package lists"
    exit 1
fi

REQUIRED_PACKAGES=(
    curl
    wget
    socat
    conntrack
    ipset
    haproxy
    ca-certificates
    containerd
)

for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package "; then
        log "Installing $package..."
        if ! sudo apt-get install -y "$package"; then
            log_error "Failed to install $package"
            exit 1
        fi
    else
        log "✓ $package already installed"
    fi
done

# Verify containerd runtime is available
log "Verifying containerd runtime is available..."
if ! command -v containerd >/dev/null 2>&1; then
    log_error "containerd command not found"
    exit 1
fi

# Check containerd version
CONTAINERD_VERSION=$(containerd --version | cut -d' ' -f3)
log "✓ containerd version: ${CONTAINERD_VERSION}"

# Verify system configuration for Kubernetes
log "Verifying system configuration for Kubernetes..."

# Check if containerd service is running
if ! sudo systemctl is-active containerd >/dev/null 2>&1; then
    log_warn "containerd service is not running, starting it..."
    if ! sudo systemctl start containerd; then
        log_error "Failed to start containerd service"
        exit 1
    fi
    if ! sudo systemctl enable containerd; then
        log_error "Failed to enable containerd service"
        exit 1
    fi
fi

# Verify containerd is working
if ! sudo systemctl is-active containerd >/dev/null 2>&1; then
    log_error "containerd service is not running! Check system setup"
    exit 1
fi

log_success "containerd service is running"

# Check system requirements
log "Checking system requirements..."

# Check memory (should have at least 2GB)
MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEMORY_GB=$((MEMORY_KB / 1024 / 1024))

if [[ $MEMORY_GB -lt 2 ]]; then
    log_warn "System has ${MEMORY_GB}GB memory, recommended minimum is 2GB"
else
    log "✓ System memory: ${MEMORY_GB}GB"
fi

# Check disk space (should have at least 20GB free)
AVAILABLE_GB=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
if [[ $AVAILABLE_GB -lt 20 ]]; then
    log_warn "Available disk space: ${AVAILABLE_GB}GB, recommended minimum is 20GB"
else
    log "✓ Available disk space: ${AVAILABLE_GB}GB"
fi

# Check if we're on the master-1 node (where most scripts should run)
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" == "master-1" ]]; then
    log "✓ Running on master-1 node (correct for most operations)"
    
    # Additional checks for master-1
    log "Checking network connectivity to other nodes..."
    
    # Check connectivity to master-2
    if ping -c 1 192.168.5.12 >/dev/null 2>&1; then
        log "✓ Can reach master-2 (192.168.5.12)"
    else
        log_warn "Cannot reach master-2 (192.168.5.12)"
    fi
    
    # Check connectivity to workers
    for worker_ip in 192.168.5.21 192.168.5.22; do
        if ping -c 1 "$worker_ip" >/dev/null 2>&1; then
            log "✓ Can reach worker ($worker_ip)"
        else
            log_warn "Cannot reach worker ($worker_ip)"
        fi
    done
    
    # Check connectivity to load balancer
    if ping -c 1 192.168.5.30 >/dev/null 2>&1; then
        log "✓ Can reach load balancer (192.168.5.30)"
    else
        log_warn "Cannot reach load balancer (192.168.5.30)"
    fi
else
    log "Running on $HOSTNAME"
fi

# Verify kubectl is not installed (to avoid conflicts)
if command -v kubectl >/dev/null 2>&1; then
    log_warn "kubectl is already installed, version: $(kubectl version --client --short 2>/dev/null || echo 'unknown')"
else
    log "✓ kubectl not installed (good, will be installed later)"
fi

# Check swap is disabled (required for Kubernetes)
if swapon --show 2>/dev/null | grep -q "/"; then
    log_warn "Swap is enabled. Kubernetes requires swap to be disabled."
    log "Disabling swap..."
    if ! sudo swapoff -a; then
        log_error "Failed to disable swap"
        exit 1
    fi
    # Remove swap entries from /etc/fstab
    sudo sed -i '/swap/d' /etc/fstab
    log "✓ Swap disabled"
else
    log "✓ Swap is already disabled"
fi

# Create status file to indicate this phase completed successfully
echo "PHASE1_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase1_status"
echo "HOSTNAME=${HOSTNAME}" >> "${SCRIPT_DIR}/.phase1_status"

log_success "Phase 1: Prerequisites setup completed successfully"
log ""
log "Next step: Run phase2-certificates.sh"

exit 0
