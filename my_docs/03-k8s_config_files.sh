#!/bin/bash

# generate-kubeconfigs.sh
# Purpose: Generate all Kubernetes configuration files (kubeconfigs)
# Run on: master-1

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CERT_DIR="./certs"
CA_DIR="${CERT_DIR}/ca"
CLIENT_DIR="${CERT_DIR}/client"
KUBECONFIG_DIR="./kubeconfigs"

# Network Configuration
LOADBALANCER_ADDRESS="192.168.5.30"
LOCALHOST_ADDRESS="127.0.0.1"
API_SERVER_PORT="6443"

# Kubeconfig files to generate
KUBECONFIGS=("kube-proxy" "kube-controller-manager" "kube-scheduler" "admin")

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

# Setup directory structure
setup_directories() {
    log "Setting up kubeconfig directory structure..."
    
    mkdir -p "${KUBECONFIG_DIR}"
    chmod 700 "${KUBECONFIG_DIR}"
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please run kubectl installation first."
        exit 1
    fi
    
    # Check if certificate directory exists
    if [[ ! -d "$CERT_DIR" ]]; then
        error "Certificate directory not found. Please run certificate generation first."
        exit 1
    fi
    
    # Check required certificates
    local required_certs=(
        "${CA_DIR}/ca.crt"
        "${CLIENT_DIR}/admin.crt"
        "${CLIENT_DIR}/admin.key"
        "${CLIENT_DIR}/kube-proxy.crt"
        "${CLIENT_DIR}/kube-proxy.key"
        "${CLIENT_DIR}/kube-controller-manager.crt"
        "${CLIENT_DIR}/kube-controller-manager.key"
        "${CLIENT_DIR}/kube-scheduler.crt"
        "${CLIENT_DIR}/kube-scheduler.key"
    )
    
    for cert in "${required_certs[@]}"; do
        if [[ ! -f "$cert" ]]; then
            error "Required certificate not found: $cert"
            exit 1
        fi
    done
    
    log "All prerequisites verified"
}

# Generate kubeconfig for kube-proxy
generate_kube_proxy_kubeconfig() {
    log "Generating kubeconfig for kube-proxy..."
    
    local kubeconfig_file="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"
    
    # Set cluster configuration
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CA_DIR}/ca.crt" \
        --embed-certs=true \
        --server="https://${LOADBALANCER_ADDRESS}:${API_SERVER_PORT}" \
        --kubeconfig="$kubeconfig_file"
    
    # Set credentials
    kubectl config set-credentials system:kube-proxy \
        --client-certificate="${CLIENT_DIR}/kube-proxy.crt" \
        --client-key="${CLIENT_DIR}/kube-proxy.key" \
        --embed-certs=true \
        --kubeconfig="$kubeconfig_file"
    
    # Set context
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-proxy \
        --kubeconfig="$kubeconfig_file"
    
    # Use context
    kubectl config use-context default --kubeconfig="$kubeconfig_file"
    
    # Set proper permissions
    chmod 600 "$kubeconfig_file"
    
    log "kube-proxy kubeconfig generated successfully"
}

# Generate kubeconfig for kube-controller-manager
generate_kube_controller_manager_kubeconfig() {
    log "Generating kubeconfig for kube-controller-manager..."
    
    local kubeconfig_file="${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig"
    
    # Set cluster configuration (uses localhost since it runs on master)
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CA_DIR}/ca.crt" \
        --embed-certs=true \
        --server="https://${LOCALHOST_ADDRESS}:${API_SERVER_PORT}" \
        --kubeconfig="$kubeconfig_file"
    
    # Set credentials
    kubectl config set-credentials system:kube-controller-manager \
        --client-certificate="${CLIENT_DIR}/kube-controller-manager.crt" \
        --client-key="${CLIENT_DIR}/kube-controller-manager.key" \
        --embed-certs=true \
        --kubeconfig="$kubeconfig_file"
    
    # Set context
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-controller-manager \
        --kubeconfig="$kubeconfig_file"
    
    # Use context
    kubectl config use-context default --kubeconfig="$kubeconfig_file"
    
    # Set proper permissions
    chmod 600 "$kubeconfig_file"
    
    log "kube-controller-manager kubeconfig generated successfully"
}

# Generate kubeconfig for kube-scheduler
generate_kube_scheduler_kubeconfig() {
    log "Generating kubeconfig for kube-scheduler..."
    
    local kubeconfig_file="${KUBECONFIG_DIR}/kube-scheduler.kubeconfig"
    
    # Set cluster configuration (uses localhost since it runs on master)
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CA_DIR}/ca.crt" \
        --embed-certs=true \
        --server="https://${LOCALHOST_ADDRESS}:${API_SERVER_PORT}" \
        --kubeconfig="$kubeconfig_file"
    
    # Set credentials
    kubectl config set-credentials system:kube-scheduler \
        --client-certificate="${CLIENT_DIR}/kube-scheduler.crt" \
        --client-key="${CLIENT_DIR}/kube-scheduler.key" \
        --embed-certs=true \
        --kubeconfig="$kubeconfig_file"
    
    # Set context
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-scheduler \
        --kubeconfig="$kubeconfig_file"
    
    # Use context
    kubectl config use-context default --kubeconfig="$kubeconfig_file"
    
    # Set proper permissions
    chmod 600 "$kubeconfig_file"
    
    log "kube-scheduler kubeconfig generated successfully"
}

# Generate kubeconfig for admin
generate_admin_kubeconfig() {
    log "Generating kubeconfig for admin..."
    
    local kubeconfig_file="${KUBECONFIG_DIR}/admin.kubeconfig"
    
    # Set cluster configuration (uses localhost for admin)
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CA_DIR}/ca.crt" \
        --embed-certs=true \
        --server="https://${LOCALHOST_ADDRESS}:${API_SERVER_PORT}" \
        --kubeconfig="$kubeconfig_file"
    
    # Set credentials
    kubectl config set-credentials admin \
        --client-certificate="${CLIENT_DIR}/admin.crt" \
        --client-key="${CLIENT_DIR}/admin.key" \
        --embed-certs=true \
        --kubeconfig="$kubeconfig_file"
    
    # Set context
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=admin \
        --kubeconfig="$kubeconfig_file"
    
    # Use context
    kubectl config use-context default --kubeconfig="$kubeconfig_file"
    
    # Set proper permissions
    chmod 600 "$kubeconfig_file"
    
    log "admin kubeconfig generated successfully"
}

# Validate kubeconfig files
validate_kubeconfigs() {
    log "Validating generated kubeconfig files..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        
        if [[ -f "$kubeconfig_file" ]]; then
            # Check if kubeconfig is valid YAML
            if kubectl config view --kubeconfig="$kubeconfig_file" &> /dev/null; then
                log "✓ ${config}.kubeconfig is valid"
            else
                error "✗ ${config}.kubeconfig is invalid"
                return 1
            fi
            
            # Check file permissions
            local perm=$(stat -c "%a" "$kubeconfig_file")
            if [[ "$perm" == "600" ]]; then
                log "✓ ${config}.kubeconfig has correct permissions (600)"
            else
                warning "✗ ${config}.kubeconfig has incorrect permissions ($perm, expected 600)"
            fi
        else
            error "✗ ${config}.kubeconfig not found"
            return 1
        fi
    done
}

# Distribute kubeconfigs to worker nodes
distribute_to_workers() {
    log "Distributing kube-proxy kubeconfig to worker nodes..."
    
    local worker_nodes=("worker-1" "worker-2")
    local kubeconfig_file="${KUBECONFIG_DIR}/kube-proxy.kubeconfig"
    
    for worker in "${worker_nodes[@]}"; do
        if scp -o StrictHostKeyChecking=no "$kubeconfig_file" "vagrant@${worker}:~/"; then
            log "✓ kube-proxy.kubeconfig copied to ${worker}"
            
            # Set proper permissions on remote node
            ssh -o StrictHostKeyChecking=no "vagrant@${worker}" 'chmod 600 ~/kube-proxy.kubeconfig'
        else
            error "✗ Failed to copy kube-proxy.kubeconfig to ${worker}"
            return 1
        fi
    done
}

# Distribute kubeconfigs to master nodes
distribute_to_masters() {
    log "Distributing kubeconfigs to master nodes..."
    
    local master_configs=("admin.kubeconfig" "kube-controller-manager.kubeconfig" "kube-scheduler.kubeconfig")
    
    # Copy to master-2 (master-1 already has them locally)
    local files_to_copy=""
    for config in "${master_configs[@]}"; do
        files_to_copy+="${KUBECONFIG_DIR}/${config} "
    done
    
    if scp -o StrictHostKeyChecking=no $files_to_copy "vagrant@master-2:~/"; then
        log "✓ Master kubeconfigs copied to master-2"
        
        # Set proper permissions on master-2
        ssh -o StrictHostKeyChecking=no "vagrant@master-2" 'chmod 600 ~/*.kubeconfig'
    else
        error "✗ Failed to copy master kubeconfigs to master-2"
        return 1
    fi
}

# Display kubeconfig information
display_kubeconfig_info() {
    log "Displaying kubeconfig information..."
    
    echo ""
    echo "Generated Kubeconfigs:"
    echo "====================="
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            echo "${config}.kubeconfig:"
            echo "  Cluster: $(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.clusters[0].name}')"
            echo "  User: $(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.users[0].name}')"
            echo "  Server: $(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.clusters[0].cluster.server}')"
            echo ""
        fi
    done
}

# Main execution
main() {
    echo "=================================================="
    echo "Kubernetes Configuration Files Generation"
    echo "Load Balancer: ${LOADBALANCER_ADDRESS}:${API_SERVER_PORT}"
    echo "Local API Server: ${LOCALHOST_ADDRESS}:${API_SERVER_PORT}"
    echo "=================================================="
    
    # Check if running on master-1
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        exit 1
    fi
    
    # Setup and verify
    setup_directories
    verify_prerequisites
    
    # Generate all kubeconfigs
    generate_kube_proxy_kubeconfig
    generate_kube_controller_manager_kubeconfig
    generate_kube_scheduler_kubeconfig
    generate_admin_kubeconfig
    
    # Validate generated files
    validate_kubeconfigs
    
    # Distribute to nodes
    distribute_to_workers
    distribute_to_masters
    
    # Display information
    display_kubeconfig_info
    
    log "All kubeconfig files generated and distributed successfully!"
    
    echo ""
    echo "=================================================="
    echo "KUBECONFIG SUMMARY"
    echo "=================================================="
    echo "Local kubeconfigs: ${KUBECONFIG_DIR}/"
    echo "Worker nodes: kube-proxy.kubeconfig distributed"
    echo "Master nodes: admin, controller-manager, scheduler kubeconfigs distributed"
    echo "File permissions: 600 (secure)"
    echo "=================================================="
}

# Run main function
main