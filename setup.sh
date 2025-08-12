#!/bin/bash

#===============================================================================
# SETUP SCRIPT
# Initial setup and validation for Kubernetes The Hard Way - Modernized
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colo

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✓${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ✗${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠${NC} $1"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "=== Kubernetes The Hard Way - Modernized Setup ==="
log "Script directory: ${SCRIPT_DIR}"

# Check if we're in the right environment
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    log_error "config.env not found. Something is wrong with the setup."
    exit 1
fi

# Load configuration
source "${SCRIPT_DIR}/config.env"

# Check if we're running on the correct node
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" != "master-1" ]]; then
    log_warn "This setup should typically be run from master-1, but you're on ${HOSTNAME}"
    log "Are you sure you want to continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Setup cancelled"
        exit 0
    fi
fi

# Validate network connectivity
log "Validating network connectivity..."

# Check if we can reach other nodes
failed_nodes=()

# Check master nodes
if ping -c 1 -W 2 "$MASTER_1_IP" >/dev/null 2>&1; then
    log_success "Can reach master-1 (${MASTER_1_IP})"
else
    log_warn "Cannot reach master-1 (${MASTER_1_IP})"
    failed_nodes+=("master-1")
fi

if ping -c 1 -W 2 "$MASTER_2_IP" >/dev/null 2>&1; then
    log_success "Can reach master-2 (${MASTER_2_IP})"
else
    log_warn "Cannot reach master-2 (${MASTER_2_IP})"
    failed_nodes+=("master-2")
fi

# Check worker nodes  
if ping -c 1 -W 2 "$WORKER_1_IP" >/dev/null 2>&1; then
    log_success "Can reach worker-1 (${WORKER_1_IP})"
else
    log_warn "Cannot reach worker-1 (${WORKER_1_IP})"
    failed_nodes+=("worker-1")
fi

if ping -c 1 -W 2 "$WORKER_2_IP" >/dev/null 2>&1; then
    log_success "Can reach worker-2 (${WORKER_2_IP})"
else
    log_warn "Cannot reach worker-2 (${WORKER_2_IP})"
    failed_nodes+=("worker-2")
fi

# Check load balancer
if ping -c 1 -W 2 "$LOADBALANCER_IP" >/dev/null 2>&1; then
    log_success "Can reach load balancer (${LOADBALANCER_IP})"
else
    log_warn "Cannot reach load balancer (${LOADBALANCER_IP})"
    failed_nodes+=("loadbalancer")
fi

if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    log_warn "Some nodes are not reachable: ${failed_nodes[*]}"
    log "This might be expected if VMs are not all started yet."
    log "Continue anyway? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
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

required_tools=(
    "openssl"
    "wget"
    "curl" 
    "ssh"
    "scp"
)

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
    log "Please install missing tools and run setup again"
    exit 1
fi

# List all available phase scripts
log "Available phase scripts:"
phase_scripts=(
    "phase1-prerequisites.sh"
    "phase2-certificates.sh"
    "phase3-kubeconfig.sh"
    "phase4-encryption.sh"
    "phase5-etcd.sh"
    "phase6-control-plane.sh"
    "phase7-workers.sh"
    "phase8-networking.sh"
    "phase9-dns.sh"
    "phase10-smoke-tests.sh"
)

for script in "${phase_scripts[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
        log_success "${script} - Available"
    else
        log_warn "${script} - Not found"
    fi
done

# Make all scripts executable
log "Making scripts executable..."
chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true

# Clean up any previous status files if requested
if [[ "${1:-}" == "--clean" ]]; then
    log "Cleaning up previous phase status files..."
    rm -f "${SCRIPT_DIR}"/.phase*_status
    log_success "Previous status files cleaned"
fi

# Check if any phases have already been completed
completed_phases=()
for i in {1..10}; do
    if [[ -f "${SCRIPT_DIR}/.phase${i}_status" ]]; then
        completed_phases+=("phase${i}")
    fi
done

if [[ ${#completed_phases[@]} -gt 0 ]]; then
    log "Previously completed phases: ${completed_phases[*]}"
    log "Use --clean option to reset all phases"
fi

log_success "Setup validation completed!"
log ""
log "Ready to start Kubernetes cluster setup."
log ""
log "Phase execution order:"
log "  1. ./phase1-prerequisites.sh    - Install packages and prepare system"
log "  2. ./phase2-certificates.sh     - Generate all SSL certificates"
log "  3. ./phase3-kubeconfig.sh       - Create kubeconfig files"
log "  4. ./phase4-encryption.sh       - Generate encryption config"
log "  5. ./phase5-etcd.sh            - Setup etcd cluster"
log "  6. ./phase6-control-plane.sh    - Setup Kubernetes control plane"
log "  7. ./phase7-workers.sh          - Setup worker nodes"
log "  8. ./phase8-networking.sh       - Setup pod networking"
log "  9. ./phase9-dns.sh             - Setup DNS and RBAC"
log " 10. ./phase10-smoke-tests.sh     - Run verification tests"
log ""
log "Start with: ./phase1-prerequisites.sh"

exit 0
