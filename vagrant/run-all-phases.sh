#!/bin/bash
# Master script to run all Kubernetes setup phases from master-1
# Run this script on master-1 node

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

log ""
log "🚀 ${YELLOW}Starting Complete Kubernetes Cluster Setup${NC}"
log "Running from: $(hostname)"
log "Started at: $(date)"
log ""

# Check if we're on master-1
if [[ "$(hostname)" != "master-1" ]]; then
    log_error "This script must be run on master-1 node!"
    exit 1
fi

# Array of phases
phases=(
    "phase1-prerequisites.sh:Prerequisites Setup"
    "phase2-certificates.sh:SSL Certificates"
    "phase3-kubeconfig.sh:Kubeconfig Files"
    "phase4-encryption.sh:Data Encryption"
    "phase5-etcd.sh:etcd Cluster"
    "phase6-control-plane.sh:Control Plane"
    "phase7-workers.sh:Worker Nodes"
    "phase8-networking.sh:Pod Networking"
    "phase9-dns.sh:DNS Addon"
    "phase10-smoke-tests.sh:Smoke Tests"
)

# Track failed phases
failed_phases=()
completed_phases=()

log "${YELLOW}Executing ${#phases[@]} phases...${NC}"
log ""

for phase_info in "${phases[@]}"; do
    IFS=':' read -r script_name description <<< "$phase_info"
    
    log "📋 ${YELLOW}Starting Phase: $description${NC}"
    log "   Script: $script_name"
    
    if [[ -f "./$script_name" ]]; then
        chmod +x "./$script_name"
        
        # Run the phase script
        if "./$script_name"; then
            log_success "✅ Phase completed: $description"
            completed_phases+=("$description")
        else
            log_error "❌ Phase failed: $description"
            failed_phases+=("$description")
            
            # Ask user if they want to continue
            log ""
            log_warning "Phase '$description' failed!"
            read -p "Do you want to continue with the next phase? (y/N): " -n 1 -r
            echo
            
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Setup interrupted by user."
                break
            fi
        fi
    else
        log_error "Script not found: $script_name"
        failed_phases+=("$description")
    fi
    
    log ""
    log "────────────────────────────────────────────────────"
    log ""
done

# Summary
log ""
log "🎯 ${YELLOW}SETUP COMPLETE - SUMMARY${NC}"
log "Finished at: $(date)"
log ""

if [[ ${#completed_phases[@]} -gt 0 ]]; then
    log_success "✅ Completed phases (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do
        log_success "   ✓ $phase"
    done
    log ""
fi

if [[ ${#failed_phases[@]} -gt 0 ]]; then
    log_error "❌ Failed phases (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do
        log_error "   ✗ $phase"
    done
    log ""
    log_warning "Some phases failed. Please check the logs and re-run failed phases manually."
    exit 1
else
    log_success "🎉 ALL PHASES COMPLETED SUCCESSFULLY!"
    log ""
    log "${CYAN}Your Kubernetes cluster is now ready!${NC}"
    log ""
    log "${YELLOW}Next steps:${NC}"
    log "  1. Test your cluster: kubectl get nodes"
    log "  2. Deploy applications: kubectl create deployment..."
    log "  3. Access dashboard or run additional tests"
    log ""
fi
