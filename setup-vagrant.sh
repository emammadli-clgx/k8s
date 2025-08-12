#!/bin/bash

#===============================================================================
# KUBERNETES THE HARD WAY - MODERNIZED SETUP (Vagrant Version)
# This script orchestrates the complete Kubernetes cluster setup
# Run from: vagrant/ directory using PowerShell with vagrant ssh commands
#===============================================================================

set -euo pipefail

# Get script directory and load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1"
}

# Check if running from vagrant directory
if [[ ! -f "Vagrantfile" ]]; then
    log_error "This script must be run from the vagrant/ directory"
    log "Please run: cd vagrant && ../setup-vagrant.sh"
    exit 1
fi

log "=== Kubernetes The Hard Way - Modernized Setup (Vagrant Version) ==="
log "Script directory: ${SCRIPT_DIR}"

# Check Vagrant status
log "Checking Vagrant VM status..."
if ! command -v vagrant >/dev/null 2>&1; then
    log_error "Vagrant is not installed or not in PATH"
    exit 1
fi

# Get VM status
vm_status=$(vagrant status --machine-readable | grep -E "state," | cut -d, -f4)
running_vms=0
total_vms=0

while IFS= read -r status; do
    total_vms=$((total_vms + 1))
    if [[ "$status" == "running" ]]; then
        running_vms=$((running_vms + 1))
    fi
done <<< "$vm_status"

log "VM Status: ${running_vms}/${total_vms} VMs running"

if [[ $running_vms -eq 0 ]]; then
    log_error "No VMs are running. Please start VMs with: vagrant up"
    exit 1
elif [[ $running_vms -lt $total_vms ]]; then
    log_warn "Not all VMs are running. Consider starting all with: vagrant up"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Setup cancelled"
        exit 0
    fi
fi

# Test SSH connectivity to VMs
log "Testing SSH connectivity to VMs..."
failed_vms=()

for vm in master-1 master-2 worker-1 worker-2 loadbalancer; do
    if vagrant ssh "$vm" -c "echo 'SSH test successful'" >/dev/null 2>&1; then
        log_success "Can SSH to $vm"
    else
        log_warn "Cannot SSH to $vm"
        failed_vms+=("$vm")
    fi
done

if [[ ${#failed_vms[@]} -gt 0 ]]; then
    log_warn "Some VMs are not accessible via SSH: ${failed_vms[*]}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Setup cancelled"
        exit 0
    fi
fi

# Create working directories
log "Creating working directories..."
mkdir -p "${CERT_DIR}" "${CONFIG_DIR}"

if [[ -d "${CERT_DIR}" ]] && [[ -d "${CONFIG_DIR}" ]]; then
    log_success "Working directories created:"
    log "  Certificates: ${CERT_DIR}"
    log "  Configs: ${CONFIG_DIR}"
else
    log_error "Failed to create working directories"
    exit 1
fi

# Check for required tools
log "Checking for required tools..."

required_tools=("openssl" "wget" "curl")
missing_tools=()

for tool in "${required_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        log_success "$tool is available"
    else
        log_error "$tool is not available"
        missing_tools+=("$tool")
    fi
done

if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing_tools[*]}"
    log "Please install missing tools and try again"
    exit 1
fi

# Check for phase scripts in parent directory
log "Checking for phase scripts..."
phase_scripts=(
    "../phase1-prerequisites.sh"
    "../phase2-certificates.sh"
    "../phase3-kubeconfig.sh"
    "../phase4-encryption.sh"
    "../phase5-etcd.sh"
    "../phase6-control-plane.sh"
    "../phase7-workers.sh"
    "../phase8-networking.sh"
    "../phase9-dns.sh"
    "../phase10-smoke-tests.sh"
)

missing_scripts=()
available_scripts=()

for script in "${phase_scripts[@]}"; do
    script_name=$(basename "$script")
    if [[ -f "$script" ]] && [[ -r "$script" ]]; then
        log_success "$script_name - Available"
        available_scripts+=("$script")
    else
        log_error "$script_name - Missing or not readable"
        missing_scripts+=("$script")
    fi
done

if [[ ${#missing_scripts[@]} -gt 0 ]]; then
    log_error "Missing phase scripts: ${missing_scripts[*]}"
    exit 1
fi

# Make scripts executable
log "Making scripts executable..."
chmod +x "${available_scripts[@]}"

log_success "Setup validation completed!"
log ""
log "Ready to start Kubernetes cluster setup from vagrant/ directory."
log ""
log "Phase execution order:"
log "  1. ../phase1-prerequisites.sh    - Install packages and prepare system"
log "  2. ../phase2-certificates.sh     - Generate all SSL certificates"
log "  3. ../phase3-kubeconfig.sh       - Create kubeconfig files"
log "  4. ../phase4-encryption.sh       - Generate encryption config"
log "  5. ../phase5-etcd.sh            - Setup etcd cluster"
log "  6. ../phase6-control-plane.sh    - Setup Kubernetes control plane"
log "  7. ../phase7-workers.sh          - Setup worker nodes"
log "  8. ../phase8-networking.sh       - Setup pod networking"
log "  9. ../phase9-dns.sh             - Setup DNS and RBAC"
log " 10. ../phase10-smoke-tests.sh     - Run verification tests"
log ""
log "Start with: ../phase1-prerequisites.sh"
log ""
log "Note: All commands will use 'vagrant ssh <vm>' to execute on VMs"
