#!/bin/bash

# verify-k8s-control-plane.sh
# Purpose: Verify Kubernetes control plane health and functionality
# Run on: any master node after all nodes are configured

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

error() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Test Kubernetes binary installation
test_k8s_binaries() {
    log "Testing Kubernetes binary installation..."
    
    local binaries=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "kubectl")
    
    for binary in "${binaries[@]}"; do
        if command -v "$binary" >/dev/null 2>&1; then
            success "$binary binary installed"
        else
            error "$binary binary not found"
        fi
    done
}

# Test service status
test_service_status() {
    log "Testing Kubernetes service status..."
    
    local services=("kube-apiserver" "kube-controller-manager" "kube-scheduler")
    
    for service in "${services[@]}"; do
        if sudo systemctl is-active --quiet "$service"; then
            success "$service is active"
        else
            error "$service is not active"
        fi
        
        if sudo systemctl is-enabled --quiet "$service"; then
            success "$service is enabled"
        else
            error "$service is not enabled"
        fi
    done
}

# Test API server connectivity
test_api_connectivity() {
    log "Testing API server connectivity..."
    
    if [[ -f "$HOME/admin.kubeconfig" ]]; then
        success "admin.kubeconfig found"
        
        if kubectl get componentstatuses --kubeconfig="$HOME/admin.kubeconfig" >/dev/null 2>&1; then
            success "API server is responding"
            
            info "Component status:"
            kubectl get componentstatuses --kubeconfig="$HOME/admin.kubeconfig" | while IFS= read -r line; do
                info "  $line"
            done
        else
            error "API server is not responding"
        fi
    else
        error "admin.kubeconfig not found"
    fi
}

# Test cluster health
test_cluster_health() {
    log "Testing cluster health..."
    
    if [[ -f "$HOME/admin.kubeconfig" ]]; then
        # Test nodes
        if kubectl get nodes --kubeconfig="$HOME/admin.kubeconfig" >/dev/null 2>&1; then
            success "Can query cluster nodes"
        else
            error "Cannot query cluster nodes"
        fi
        
        # Test namespaces
        if kubectl get namespaces --kubeconfig="$HOME/admin.kubeconfig" >/dev/null 2>&1; then
            success "Can query cluster namespaces"
        else
            error "Cannot query cluster namespaces"
        fi
        
        # Test API server version
        local api_version=$(kubectl version --kubeconfig="$HOME/admin.kubeconfig" --output=json 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || echo "unknown")
        if [[ "$api_version" != "unknown" ]]; then
            success "API server version: $api_version"
        else
            error "Cannot get API server version"
        fi
    fi
}

# Test certificates
test_certificates() {
    log "Testing certificate configuration..."
    
    local k8s_lib_dir="/var/lib/kubernetes"
    local required_certs=(
        "ca.crt" "ca.key"
        "kube-apiserver.crt" "kube-apiserver.key"
        "service-account.crt" "service-account.key"
        "etcd-server.crt" "etcd-server.key"
    )
    
    for cert in "${required_certs[@]}"; do
        local cert_path="${k8s_lib_dir}/${cert}"
        if [[ -f "$cert_path" ]]; then
            success "Certificate exists: $cert"
            
            # Check permissions
            local perm=$(stat -c "%a" "$cert_path")
            local expected_perm="644"
            if [[ "$cert" == *.key ]]; then
                expected_perm="600"
            fi
            
            if [[ "$perm" == "$expected_perm" ]]; then
                success "Certificate $cert has correct permissions ($perm)"
            else
                error "Certificate $cert has incorrect permissions ($perm, expected $expected_perm)"
            fi
        else
            error "Certificate missing: $cert_path"
        fi
    done
}

# Test configuration files
test_config_files() {
    log "Testing configuration files..."
    
    local k8s_lib_dir="/var/lib/kubernetes"
    local config_files=(
        "encryption-config.yaml"
        "kube-controller-manager.kubeconfig"
        "kube-scheduler.kubeconfig"
    )
    
    for config in "${config_files[@]}"; do
        local config_path="${k8s_lib_dir}/${config}"
        if [[ -f "$config_path" ]]; then
            success "Configuration file exists: $config"
        else
            error "Configuration file missing: $config_path"
        fi
    done
}

# Test etcd connectivity
test_etcd_connectivity() {
    log "Testing etcd connectivity from Kubernetes..."
    
    # This is an indirect test - if the API server is running and responding,
    # it means etcd connectivity is working
    if sudo systemctl is-active --quiet kube-apiserver; then
        success "kube-apiserver is running (indicates etcd connectivity)"
    else
        error "kube-apiserver is not running (possible etcd connectivity issue)"
    fi
}

# Main execution
main() {
    echo "=================================================="
    echo "Kubernetes Control Plane Verification"
    echo "=================================================="
    
    # Run tests
    test_k8s_binaries
    echo ""
    test_service_status
    echo ""
    test_certificates
    echo ""
    test_config_files
    echo ""
    test_etcd_connectivity
    echo ""
    test_api_connectivity
    echo ""
    test_cluster_health
    
    # Summary
    echo ""
    echo "=================================================="
    echo "TEST SUMMARY"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo ""
    
    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "${GREEN}All Kubernetes control plane tests passed!${NC}"
        echo "Your control plane is ready."
        exit 0
    else
        echo -e "${RED}Some control plane tests failed.${NC}"
        echo "Please review the errors above before proceeding."
        exit 1
    fi
}

# Run main function
main