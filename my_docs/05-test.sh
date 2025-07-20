#!/bin/bash

# verify-etcd-cluster.sh
# Purpose: Verify etcd cluster health and membership
# Run on: any master node (after all nodes are configured)

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ETCD_CONFIG_DIR="/etc/etcd"
MASTER_IPS=("192.168.5.11" "192.168.5.12")
MASTER_NAMES=("master-1" "master-2")

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

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Test etcd binary installation
test_etcd_installation() {
    log "Testing etcd binary installation..."
    
    if command -v etcd >/dev/null 2>&1; then
        local etcd_version=$(etcd --version 2>/dev/null | head -1 || echo "unknown")
        success "etcd binary installed: $etcd_version"
    else
        error "etcd binary not found in PATH"
    fi
    
    if command -v etcdctl >/dev/null 2>&1; then
        local etcdctl_version=$(etcdctl version 2>/dev/null | head -1 || echo "unknown")
        success "etcdctl binary installed: $etcdctl_version"
    else
        error "etcdctl binary not found in PATH"
    fi
}

# Test etcd service status
test_etcd_service() {
    log "Testing etcd service status..."
    
    if sudo systemctl is-active --quiet etcd; then
        success "etcd service is active"
    else
        error "etcd service is not active"
        info "Service status:"
        sudo systemctl status etcd --no-pager --lines=5
    fi
    
    if sudo systemctl is-enabled --quiet etcd; then
        success "etcd service is enabled"
    else
        error "etcd service is not enabled"
    fi
}

# Test etcd certificates
test_etcd_certificates() {
    log "Testing etcd certificates..."
    
    local certificates=("ca.crt" "etcd-server.crt" "etcd-server.key")
    
    for cert in "${certificates[@]}"; do
        local cert_path="${ETCD_CONFIG_DIR}/${cert}"
        if [[ -f "$cert_path" ]]; then
            success "Certificate exists: $cert"
            
            # Check permissions
            local perm=$(stat -c "%a" "$cert_path")
            local expected_perm="644"
            if [[ "$cert" == *".key" ]]; then
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

# Test etcd local connectivity
test_etcd_connectivity() {
    log "Testing etcd local connectivity..."
    
    # Test localhost endpoint
    if sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        endpoint health >/dev/null 2>&1; then
        success "etcd localhost endpoint healthy"
    else
        error "etcd localhost endpoint unhealthy"
    fi
    
    # Test cluster endpoints
    local healthy_endpoints=0
    for ip in "${MASTER_IPS[@]}"; do
        if sudo ETCDCTL_API=3 etcdctl \
            --endpoints=https://${ip}:2379 \
            --cacert=${ETCD_CONFIG_DIR}/ca.crt \
            --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
            --key=${ETCD_CONFIG_DIR}/etcd-server.key \
            endpoint health >/dev/null 2>&1; then
            success "etcd endpoint healthy: https://${ip}:2379"
            ((healthy_endpoints++))
        else
            error "etcd endpoint unhealthy: https://${ip}:2379"
        fi
    done
    
    if [[ $healthy_endpoints -ge 2 ]]; then
        success "etcd cluster has quorum ($healthy_endpoints/2 nodes healthy)"
    else
        error "etcd cluster lacks quorum ($healthy_endpoints/2 nodes healthy)"
    fi
}

# Test cluster membership
test_cluster_membership() {
    log "Testing etcd cluster membership..."
    
    local member_output
    if member_output=$(sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        member list 2>/dev/null); then
        
        success "etcd cluster membership retrieved"
        
        # Count members
        local member_count=$(echo "$member_output" | wc -l)
        if [[ $member_count -eq 2 ]]; then
            success "etcd cluster has correct number of members (2)"
        else
            error "etcd cluster has incorrect number of members ($member_count, expected 2)"
        fi
        
        # Check for expected members
        for name in "${MASTER_NAMES[@]}"; do
            if echo "$member_output" | grep -q "$name"; then
                success "etcd member found: $name"
            else
                error "etcd member missing: $name"
            fi
        done
        
        # Display member information
        info "Cluster members:"
        echo "$member_output" | while IFS= read -r line; do
            info "  $line"
        done
        
    else
        error "Failed to retrieve etcd cluster membership"
    fi
}

# Test basic operations
test_etcd_operations() {
    log "Testing basic etcd operations..."
    
    local test_key="test-key"
    local test_value="test-value-$(date +%s)"
    
    # Test put operation
    if sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        put "$test_key" "$test_value" >/dev/null 2>&1; then
        success "etcd put operation successful"
    else
        error "etcd put operation failed"
        return
    fi
    
    # Test get operation
    local retrieved_value
    if retrieved_value=$(sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        get "$test_key" --print-value-only 2>/dev/null); then
        
        if [[ "$retrieved_value" == "$test_value" ]]; then
            success "etcd get operation successful"
        else
            error "etcd get operation returned wrong value"
        fi
    else
        error "etcd get operation failed"
    fi
    
    # Test delete operation
    if sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        del "$test_key" >/dev/null 2>&1; then
        success "etcd delete operation successful"
    else
        error "etcd delete operation failed"
    fi
}

# Main execution
main() {
    echo "=================================================="
    echo "etcd Cluster Verification"
    echo "=================================================="
    
    # Check if etcd config directory exists
    if [[ ! -d "$ETCD_CONFIG_DIR" ]]; then
        error "etcd config directory not found. Run bootstrap script first."
        exit 1
    fi
    
    # Run tests
    test_etcd_installation
    echo ""
    test_etcd_service
    echo ""
    test_etcd_certificates
    echo ""
    test_etcd_connectivity
    echo ""
    test_cluster_membership
    echo ""
    test_etcd_operations
    
    # Summary
    echo ""
    echo "=================================================="
    echo "TEST SUMMARY"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo ""
    
    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "${GREEN}All etcd cluster tests passed!${NC}"
        echo "Your etcd cluster is ready for Kubernetes."
        exit 0
    else
        echo -e "${RED}Some etcd cluster tests failed.${NC}"
        echo "Please review the errors above before proceeding."
        exit 1
    fi
}

# Run main function
main