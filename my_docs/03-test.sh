#!/bin/bash

# test-kubeconfigs.sh
# Purpose: Test and validate all generated kubeconfig files
# Run on: master-1

set -uo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Configuration
KUBECONFIG_DIR="./kubeconfigs"
KUBECONFIGS=("kube-proxy" "kube-controller-manager" "kube-scheduler" "admin")
WORKER_NODES=("worker-1" "worker-2")

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

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test kubeconfig file existence
test_kubeconfig_existence() {
    log "Testing kubeconfig file existence..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            success "Kubeconfig ${config}.kubeconfig exists"
        else
            error "Kubeconfig ${config}.kubeconfig missing"
        fi
    done
}

# Test kubeconfig file permissions
test_kubeconfig_permissions() {
    log "Testing kubeconfig file permissions..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            local perm=$(stat -c "%a" "$kubeconfig_file")
            if [[ "$perm" == "600" ]]; then
                success "Kubeconfig ${config}.kubeconfig has correct permissions (600)"
            else
                error "Kubeconfig ${config}.kubeconfig has incorrect permissions ($perm, expected 600)"
            fi
        fi
    done
}

# Test kubeconfig file validity
test_kubeconfig_validity() {
    log "Testing kubeconfig file validity..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            if kubectl config view --kubeconfig="$kubeconfig_file" &> /dev/null; then
                success "Kubeconfig ${config}.kubeconfig is valid YAML"
            else
                error "Kubeconfig ${config}.kubeconfig is invalid YAML"
            fi
        fi
    done
}

# Test kubeconfig structure
test_kubeconfig_structure() {
    log "Testing kubeconfig structure..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            # Test cluster configuration
            local cluster_name=$(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
            if [[ "$cluster_name" == "kubernetes-the-hard-way" ]]; then
                success "Kubeconfig ${config}.kubeconfig has correct cluster name"
            else
                error "Kubeconfig ${config}.kubeconfig has incorrect cluster name: $cluster_name"
            fi
            
            # Test user configuration
            local user_name=$(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.users[0].name}' 2>/dev/null || echo "")
            local expected_user=""
            case $config in
                "admin") expected_user="admin" ;;
                "kube-proxy") expected_user="system:kube-proxy" ;;
                "kube-controller-manager") expected_user="system:kube-controller-manager" ;;
                "kube-scheduler") expected_user="system:kube-scheduler" ;;
            esac
            
            if [[ "$user_name" == "$expected_user" ]]; then
                success "Kubeconfig ${config}.kubeconfig has correct user name"
            else
                error "Kubeconfig ${config}.kubeconfig has incorrect user name: $user_name (expected: $expected_user)"
            fi
            
            # Test server configuration
            local server_url=$(kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
            if [[ -n "$server_url" ]] && [[ "$server_url" == https://* ]]; then
                success "Kubeconfig ${config}.kubeconfig has valid server URL"
            else
                error "Kubeconfig ${config}.kubeconfig has invalid server URL: $server_url"
            fi
        fi
    done
}

# Test certificate embedding
test_certificate_embedding() {
    log "Testing certificate embedding..."
    
    for config in "${KUBECONFIGS[@]}"; do
        local kubeconfig_file="${KUBECONFIG_DIR}/${config}.kubeconfig"
        if [[ -f "$kubeconfig_file" ]]; then
            # Check if CA certificate is embedded
            if kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | grep -q .; then
                success "Kubeconfig ${config}.kubeconfig has embedded CA certificate"
            else
                error "Kubeconfig ${config}.kubeconfig missing embedded CA certificate"
            fi
            
            # Check if client certificate is embedded
            if kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null | grep -q .; then
                success "Kubeconfig ${config}.kubeconfig has embedded client certificate"
            else
                error "Kubeconfig ${config}.kubeconfig missing embedded client certificate"
            fi
            
            # Check if client key is embedded
            if kubectl config view --kubeconfig="$kubeconfig_file" -o jsonpath='{.users[0].user.client-key-data}' 2>/dev/null | grep -q .; then
                success "Kubeconfig ${config}.kubeconfig has embedded client key"
            else
                error "Kubeconfig ${config}.kubeconfig missing embedded client key"
            fi
        fi
    done
}

# Test distribution to worker nodes
test_worker_distribution() {
    log "Testing kubeconfig distribution to worker nodes..."
    
    for worker in "${WORKER_NODES[@]}"; do
        if ssh -o StrictHostKeyChecking=no "vagrant@${worker}" "test -f ~/kube-proxy.kubeconfig" 2>/dev/null; then
            success "kube-proxy.kubeconfig exists on ${worker}"
            
            # Test permissions on worker
            local perm=$(ssh -o StrictHostKeyChecking=no "vagrant@${worker}" "stat -c '%a' ~/kube-proxy.kubeconfig" 2>/dev/null || echo "000")
            if [[ "$perm" == "600" ]]; then
                success "kube-proxy.kubeconfig has correct permissions on ${worker} (600)"
            else
                error "kube-proxy.kubeconfig has incorrect permissions on ${worker} ($perm, expected 600)"
            fi
        else
            error "kube-proxy.kubeconfig missing on ${worker}"
        fi
    done
}

# Test distribution to master nodes
test_master_distribution() {
    log "Testing kubeconfig distribution to master-2..."
    
    local master_configs=("admin.kubeconfig" "kube-controller-manager.kubeconfig" "kube-scheduler.kubeconfig")
    
    for config in "${master_configs[@]}"; do
        if ssh -o StrictHostKeyChecking=no "vagrant@master-2" "test -f ~/${config}" 2>/dev/null; then
            success "${config} exists on master-2"
            
            # Test permissions on master-2
            local perm=$(ssh -o StrictHostKeyChecking=no "vagrant@master-2" "stat -c '%a' ~/${config}" 2>/dev/null || echo "000")
            if [[ "$perm" == "600" ]]; then
                success "${config} has correct permissions on master-2 (600)"
            else
                error "${config} has incorrect permissions on master-2 ($perm, expected 600)"
            fi
        else
            error "${config} missing on master-2"
        fi
    done
}

# Main test execution
main() {
    echo "=================================================="
    echo "Kubeconfig Test Suite"
    echo "=================================================="
    
    # Check if running on master-1
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        exit 1
    fi
    
    # Check if kubeconfig directory exists
    if [[ ! -d "$KUBECONFIG_DIR" ]]; then
        error "Kubeconfig directory not found. Run generate-kubeconfigs.sh first."
        exit 1
    fi
    
    # Run tests
    test_kubeconfig_existence
    echo ""
    test_kubeconfig_permissions
    echo ""
    test_kubeconfig_validity
    echo ""
    test_kubeconfig_structure
    echo ""
    test_certificate_embedding
    echo ""
    test_worker_distribution
    echo ""
    test_master_distribution
    
    # Summary
    echo ""
    echo "=================================================="
    echo "TEST SUMMARY"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo ""
    
    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "${GREEN}All kubeconfig tests passed!${NC}"
        echo "Your kubeconfig files are ready for Kubernetes deployment."
        exit 0
    else
        echo -e "${RED}Some kubeconfig tests failed.${NC}"
        echo "Please review the errors above before proceeding."
        exit 1
    fi
}

# Run main function
main